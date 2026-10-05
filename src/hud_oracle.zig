//! The HUD oracle: the status bar graded against the Game Boy drawing it.
//!
//! Step 13b. No trace carries the window -- every column a reference pass
//! records is WRAM -- so the band is graded against a render instead: both
//! machines stand Samus still in the landing site, the same values are written
//! into both at the same point of the same tick, and after every tick the
//! twenty window tiles the Game Boy's `VBlank_updateStatusBar` (01:$493E) drew
//! are compared tile for tile with the twenty BG2 tilemap words the cart's
//! `UpdateStatusBar` drew. The displayed counts and the shuffle timer ride
//! along, so `adjustHudValues`' roll is graded per tick too.
//!
//! **The scrambled count is graded by when, not by what.** Its digits come off
//! `rDIV` on the Game Boy and off `!DivClock` on the cart, so the two count
//! cells are masked on every tick the scramble drew -- and the timer that
//! decides which ticks those are is compared unmasked, which is what grades
//! the start (below $80) and the stop (zero).
//!
//! The rung is shown failing on every run: `fault` rebuilds the cart with the
//! digit base in `HudTens` one too high, and a cart that still agrees grades
//! nothing.

const std = @import("std");
const harness = @import("gb/harness.zig");
const room = @import("room.zig");
const oracle = @import("oracle.zig");
const offsets = @import("offsets.zig");
const snes_screen = @import("snes_screen.zig");
const snes_trace = @import("snes_trace.zig");
const inject = @import("snes_inject.zig");
const convert = @import("snes_convert.zig");
const gb_trace = @import("gb_trace.zig");

pub const Error = error{ NeverSettled, MissingSymbol, NoSaveFile, ShortSaveFile, NotTheImage, NoBoot, OutOfMemory };

// ---- The Game Boy's addresses, off the disassembly of 01:$493E-$4B61 --------

pub const gb_tanks: u16 = 0xD050;
pub const gb_health: u16 = 0xD051;
pub const gb_missiles: u16 = 0xD053;
pub const gb_disp_health: u16 = 0xD084;
pub const gb_disp_missiles: u16 = 0xD086;
pub const gb_shuffle: u16 = 0xD096;
pub const gb_met_disp: u16 = 0xD09A;
pub const gb_div: u16 = 0xFF04;
pub const gb_pose: u16 = 0xD020;
pub const gb_counter: u16 = 0xFF97;
/// `vramDest_statusBar`: the window tilemap's first row, as an index into the
/// emulator's VRAM array, which starts at $8000.
pub const gb_status_bar_vram: usize = 0x9C00 - 0x8000;
pub const status_tiles: usize = 0x14;
/// The enemy slots, emptied on both machines at the seed so nothing touches
/// Samus and moves her health. See `enemy_oracle.writeSlots`.
const gb_slots: u16 = 0xC600;
const gb_num_total: u16 = 0xC425;
const gb_num_active: u16 = 0xC426;
const gb_num_offscreen: u16 = 0xC427;

/// The scrambled arm's two `LDH A,(rDIV)`.
pub const scramble_tens_pc: u16 = 0x49F9;
pub const scramble_ones_pc: u16 = 0x4A05;

// ---- The script ------------------------------------------------------------

/// What a poke writes. Each has a Game Boy address and a cart symbol, and both
/// are written at the same point of the same tick.
pub const Field = enum {
    tanks,
    health_lo,
    health_hi,
    disp_health_lo,
    disp_health_hi,
    missiles_lo,
    missiles_hi,
    disp_missiles_lo,
    disp_missiles_hi,
    met_disp,
    shuffle,

    pub fn gb(self: Field) u16 {
        return switch (self) {
            .tanks => gb_tanks,
            .health_lo => gb_health,
            .health_hi => gb_health + 1,
            .disp_health_lo => gb_disp_health,
            .disp_health_hi => gb_disp_health + 1,
            .missiles_lo => gb_missiles,
            .missiles_hi => gb_missiles + 1,
            .disp_missiles_lo => gb_disp_missiles,
            .disp_missiles_hi => gb_disp_missiles + 1,
            .met_disp => gb_met_disp,
            .shuffle => gb_shuffle,
        };
    }

    pub fn cart(self: Field) Error!u16 {
        const base: struct { name: []const u8, plus: u16 } = switch (self) {
            .tanks => .{ .name = "VarTanks", .plus = 0 },
            .health_lo => .{ .name = "VarHealthLo", .plus = 0 },
            .health_hi => .{ .name = "VarHealthLo", .plus = 1 },
            .disp_health_lo => .{ .name = "VarDispHealthLo", .plus = 0 },
            .disp_health_hi => .{ .name = "VarDispHealthLo", .plus = 1 },
            .missiles_lo => .{ .name = "VarCurMissLo", .plus = 0 },
            .missiles_hi => .{ .name = "VarCurMissHi", .plus = 0 },
            .disp_missiles_lo => .{ .name = "VarDispMissLo", .plus = 0 },
            .disp_missiles_hi => .{ .name = "VarDispMissLo", .plus = 1 },
            .met_disp => .{ .name = "VarMetDisp", .plus = 0 },
            .shuffle => .{ .name = "VarShuffle", .plus = 0 },
        };
        const at = inject.symbol(base.name) orelse return Error.MissingSymbol;
        return @as(u16, @truncate(at)) + base.plus;
    }
};

pub const Poke = struct { tick: u16, field: Field, value: u8 };

/// A whole loadout at once, displayed equal to real so nothing rolls: the
/// shape of a static value set.
fn loadout(list: *std.ArrayList(Poke), allocator: std.mem.Allocator, tick: u16, tanks: u8, health: u16, missiles: u16, met: u8) !void {
    const vals = [_]struct { Field, u8 }{
        .{ .tanks, tanks },
        .{ .health_lo, @truncate(health) },
        .{ .health_hi, @truncate(health >> 8) },
        .{ .disp_health_lo, @truncate(health) },
        .{ .disp_health_hi, @truncate(health >> 8) },
        .{ .missiles_lo, @truncate(missiles) },
        .{ .missiles_hi, @truncate(missiles >> 8) },
        .{ .disp_missiles_lo, @truncate(missiles) },
        .{ .disp_missiles_hi, @truncate(missiles >> 8) },
        .{ .met_disp, met },
    };
    for (vals) |v| try list.append(allocator, .{ .tick = tick, .field = v[0], .value = v[1] });
}

fn bcd(n: u16) u16 {
    return (n / 1000 % 10) << 12 | (n / 100 % 10) << 8 | (n / 10 % 10) << 4 | (n % 10);
}

/// Ticks each static value set is held for. Two would do -- one to draw, one to
/// show it stayed -- and three leaves room for a bar that draws a frame late.
pub const hold: u16 = 3;
pub const roll_ticks: u16 = 12;
/// A kill's `$C0` (`LD A,$C0 / LD ($D096),A`, 02:$6D90 for the Alpha and four
/// more sites for the other Metroids; Step 13d's) and enough ticks to count it out.
pub const shuffle_start: u8 = 0xC0;
pub const shuffle_ticks: u16 = 0xC0 + 8;
/// Where, inside the scramble, Samus walks: long enough for the camera to leave
/// its clamp and stream rows, which is the frames the status bar -- and its
/// timer -- is not drawn on.
pub const walk_from: u16 = 0x10;
pub const walk_ticks: u16 = 0x40;

/// The script both machines run, and how many ticks it lasts.
pub const Script = struct {
    pokes: []Poke,
    /// The pad per tick. Held on both machines the way the segment holds it.
    keys: []oracle.Key,
    ticks: u16,
    /// The first tick of the scramble case, for the report.
    shuffle_at: u16,

    pub fn deinit(self: Script, allocator: std.mem.Allocator) void {
        allocator.free(self.pokes);
        allocator.free(self.keys);
    }
};

pub fn script(allocator: std.mem.Allocator) !Script {
    var list: std.ArrayList(Poke) = .empty;
    errdefer list.deinit(allocator);
    var t: u16 = 0;

    // No tanks, which is the `E`: the new game's own loadout.
    try loadout(&list, allocator, t, 0, 0x0099, 0x0030, 0x39);
    t += hold;
    // Every digit 0-9 in every digit cell, and one to five tanks with between
    // one and three of them full. Health never reaches zero: a displayed zero
    // is `killSamus` at 00:$04F0, which is not this step's.
    for (0..10) |d| {
        const tanks: u8 = @intCast(1 + d % 5);
        const full: u16 = (tanks + 1) / 2;
        const two: u16 = @intCast(d * 11);
        try loadout(&list, allocator, t, tanks, (full << 8) | bcd(two), bcd(@intCast(d * 111)), @intCast(bcd(two)));
        t += hold;
    }

    // The roll, both ways on both counts, across a hundreds boundary each.
    try loadout(&list, allocator, t, 2, 0x0105, 0x0037, 0x39);
    try list.append(allocator, .{ .tick = t, .field = .health_lo, .value = 0x00 }); // real $0100: five down
    try list.append(allocator, .{ .tick = t, .field = .missiles_lo, .value = 0x40 }); // real $0040: three up
    t += roll_ticks;
    try loadout(&list, allocator, t, 2, 0x0100, 0x0101, 0x39);
    try list.append(allocator, .{ .tick = t, .field = .health_lo, .value = 0x95 });
    try list.append(allocator, .{ .tick = t, .field = .health_hi, .value = 0x00 }); // $0095
    try list.append(allocator, .{ .tick = t, .field = .missiles_lo, .value = 0x98 });
    try list.append(allocator, .{ .tick = t, .field = .missiles_hi, .value = 0x00 }); // $0098
    t += roll_ticks;
    // The clamp: a real health byte outside decimal, once per nibble.
    try loadout(&list, allocator, t, 1, 0x0050, 0x0030, 0x39);
    try list.append(allocator, .{ .tick = t, .field = .health_lo, .value = 0x3C });
    t += roll_ticks;
    try loadout(&list, allocator, t, 1, 0x0090, 0x0030, 0x39);
    try list.append(allocator, .{ .tick = t, .field = .health_lo, .value = 0xA5 });
    t += roll_ticks;

    // The scramble, from a kill's timer to zero and a few ticks past it.
    const shuffle_at = t;
    try loadout(&list, allocator, t, 1, 0x0099, 0x0030, 0x47);
    try list.append(allocator, .{ .tick = t, .field = .shuffle, .value = shuffle_start });
    t += shuffle_ticks;

    const keys = try allocator.alloc(oracle.Key, t);
    @memset(keys, oracle.key.none);
    @memset(keys[shuffle_at + walk_from ..][0..walk_ticks], oracle.key.right);
    return .{ .pokes = try list.toOwnedSlice(allocator), .keys = keys, .ticks = t, .shuffle_at = shuffle_at };
}

// ---- What is recorded ------------------------------------------------------

/// After every tick: the twenty tile ids, the OR of the twenty words' high
/// bytes (zero on the Game Boy, which has no attribute to carry), both
/// displayed counts, the shuffle timer and the real health's low byte, which
/// the clamp rewrites.
pub const record_bytes: usize = status_tiles + 11;
pub const Record = [record_bytes]u8;
pub const at_attr: usize = status_tiles;
pub const at_disp_health: usize = status_tiles + 1;
pub const at_disp_missiles: usize = status_tiles + 3;
pub const at_shuffle: usize = status_tiles + 5;
pub const at_health: usize = status_tiles + 6;
/// The camera's pixel bytes, Y then X: the walk has to move both machines'
/// cameras the same way before a timer that skips stream frames can agree.
pub const at_camera: usize = status_tiles + 7;
/// Samus's pixel X and the frame counter's low byte, for the same reason.
pub const at_samus_x: usize = status_tiles + 9;
pub const at_counter: usize = status_tiles + 10;
/// The count's two cells, which the scramble writes.
pub const count_cells = [_]usize{ 18, 19 };

// ---- The Game Boy ----------------------------------------------------------

pub const GbRun = struct {
    settled: room.Placement,
    camera_x: u16,
    camera_y: u16,
    counter: u8,
    loadout: snes_screen.Loadout.Measured,
    records: []Record,

    pub fn deinit(self: *GbRun, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
    }
};

/// A new game, past the appearance and standing still.
fn standingGb(allocator: std.mem.Allocator, rom: []const u8) !harness.Machine {
    var m = try room.bootIntoPlay(allocator, rom);
    errdefer m.deinit();
    var still: usize = 0;
    var prev = room.placement(&m);
    var waited: usize = 0;
    while (waited < 2000 and (still < oracle.settle_still or m.read(gb_pose) != 0)) : (waited += 1) {
        _ = try m.runFrames(1, oracle.gbKeys(oracle.key.none));
        const now = room.placement(&m);
        still = if (now.eql(prev)) still + 1 else 0;
        prev = now;
    }
    if (m.read(gb_pose) != 0 or still < oracle.settle_still) return Error.NeverSettled;
    return m;
}

fn emptySlots(m: *harness.Machine) void {
    for (0..16 * 0x20) |i| m.write(gb_slots + @as(u16, @intCast(i)), 0xFF);
    m.write(gb_num_total, 0);
    m.write(gb_num_active, 0);
    m.write(gb_num_offscreen, 0);
}

pub fn runGb(allocator: std.mem.Allocator, rom: []const u8, s: Script) !GbRun {
    var m = try standingGb(allocator, rom);
    defer m.deinit();
    try oracle.stepToLogicPoint(&m);

    const out: GbRun = .{
        .settled = room.placement(&m),
        .camera_x = (@as(u16, m.read(room.camera_screen_x_addr)) << 8) | m.read(room.camera_pixel_x_addr),
        .camera_y = (@as(u16, m.read(room.camera_screen_y_addr)) << 8) | m.read(room.camera_pixel_y_addr),
        .counter = m.read(gb_counter),
        .loadout = oracle.gbLoadout(&m),
        .records = try allocator.alloc(Record, s.ticks),
    };
    errdefer allocator.free(out.records);

    emptySlots(&m);
    for (out.records, 0..) |*r, tick| {
        for (s.pokes) |p| {
            if (p.tick == tick) m.write(p.field.gb(), p.value);
        }
        try oracle.stepOneTick(&m, oracle.gbKeys(s.keys[tick]));
        @memcpy(r[0..status_tiles], m.sys.bus.vram[gb_status_bar_vram..][0..status_tiles]);
        r[at_attr] = 0;
        r[at_disp_health] = m.read(gb_disp_health);
        r[at_disp_health + 1] = m.read(gb_disp_health + 1);
        r[at_disp_missiles] = m.read(gb_disp_missiles);
        r[at_disp_missiles + 1] = m.read(gb_disp_missiles + 1);
        r[at_shuffle] = m.read(gb_shuffle);
        r[at_health] = m.read(gb_health);
        r[at_camera] = m.read(room.camera_pixel_y_addr);
        r[at_camera + 1] = m.read(room.camera_pixel_x_addr);
        r[at_samus_x] = room.placement(&m).pixel_x;
        r[at_counter] = m.read(gb_counter);
    }
    return out;
}

/// The cart's boot record: the new game's room, with Samus, the camera, the
/// counter's phase and the loadout where the Game Boy settled -- a handover,
/// so the cart skips the title and the appearance.
pub fn cartBoot(allocator: std.mem.Allocator, rom: []const u8, gb: GbRun) !snes_screen.Boot {
    var b = try snes_screen.newGameBoot(allocator, rom);
    b.cell = (gb.settled.screen_row << 4) | (gb.settled.screen_col & 0x0F);
    b.samus_x = gb.settled.worldX();
    b.samus_y = gb.settled.worldY();
    b.cam_x = gb.camera_x;
    b.cam_y = gb.camera_y;
    b.pose = oracle.start_pose;
    b.countdown = 0;
    b.mode = .handover;
    // One less than the enemy oracle's seed, and measured rather than argued:
    // this cart is sampled after `MainLoop`'s `wai` rather than at it, so its
    // first sample is one NMI later, and with a seed of 0 the counter byte in
    // every record reads one past the Game Boy's and the walk's 2/1 steps land
    // on the other parity. The counter is a compared byte, so the lead is
    // checked on every tick.
    b.frame_count = oracle.frameCountSeed(gb.counter, 1);
    b.loadout = gb.loadout.over(b.loadout);
    return b;
}

// ---- The cart --------------------------------------------------------------

pub const out_dir = "build-out";
pub const stem = "hud";
pub const cart_name = out_dir ++ "/" ++ stem ++ ".sfc";
pub const lua_name = out_dir ++ "/" ++ stem ++ ".lua";

fn sym(name: []const u8) Error!u32 {
    return inject.symbol(name) orelse Error.MissingSymbol;
}

pub fn writeLua(w: *std.Io.Writer, s: Script) !void {
    try w.print(
        \\-- Generated by src/hud_oracle.zig. Do not edit.
        \\local wram = emu.memType.snesWorkRam
        \\local vram = emu.memType.snesVideoRam
        \\local sram = emu.memType.snesSaveRam
        \\local COMMIT = 0x{X:0>6}
        \\local TICKS = {d}
        \\local SLOTS, TOTAL, ACTIVE, OFFSCR = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local MAP = 0x{X:0>4}
        \\local DH, DM, SH, H = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local CAMY, CAMX = 0x{X:0>4}, 0x{X:0>4}
        \\local SAMX, FC = 0x{X:0>4}, 0x{X:0>4}
        \\local RB = {d}
        \\local POKES = {{
        \\
    , .{
        try sym("MainLoop_woke"), s.ticks,
        try sym("VarSlots") & 0xFFFF,     try sym("VarEnTotal") & 0xFFFF,
        try sym("VarEnActive") & 0xFFFF,  try sym("VarEnOffscr") & 0xFFFF,
        try sym("ConstBg2Map") * 2,
        try sym("VarDispHealthLo") & 0xFFFF, try sym("VarDispMissLo") & 0xFFFF,
        try sym("VarShuffle") & 0xFFFF,   try sym("VarHealthLo") & 0xFFFF,
        try sym("VarCamY") & 0xFFFF,      try sym("VarCamX") & 0xFFFF,
        try sym("VarSamusX") & 0xFFFF,    try sym("VarFrameCount") & 0xFFFF,
        record_bytes,
    });
    // Keyed by tick, a list of (address, value) per tick.
    var tick: u16 = 0;
    while (tick < s.ticks) : (tick += 1) {
        var any = false;
        for (s.pokes) |p| {
            if (p.tick != tick) continue;
            if (!any) try w.print("  [{d}] = {{", .{tick});
            any = true;
            try w.print("{{0x{X:0>4},{d}}},", .{ try p.field.cart(), p.value });
        }
        if (any) try w.print("}},\n", .{});
    }
    try w.print("}}\nlocal KEYS = {{\n", .{});
    var keybuf: [oracle.mesen_keys_max]u8 = undefined;
    for (s.keys) |k| try w.print("  {{{s}}},\n", .{oracle.mesenKeys(k, &keybuf)});
    try w.print(
        \\}}
        \\
        \\-- COMMIT is `MainLoop_woke`, the instruction after `MainLoop`'s NMI wait,
        \\-- not `MainLoop` itself (the wait is a loop now, so `MainLoop + 1` is
        \\-- the middle of an instruction and never runs): the
        \\-- oracle's usual commit point is before NMI, and the status bar is drawn
        \\-- in NMI, so a poke there would be drawn once before the logic that rolls
        \\-- it -- where the Game Boy's poke, at 00:$052F, is rolled first and drawn
        \\-- after. Here both machines' pokes are followed by one pass of logic and
        \\-- one vblank before the record.
        \\--
        \\-- Visit i is the top of tick i-1: record what tick i-2 left, then poke
        \\-- tick i-1. Visit 1 records nothing and seeds.
        \\-- A tick's pad has to be in place before the NMI ahead of its logic, as the
        \\-- segment's is, which from here is the visit before. Tick 0's is the boot
        \\-- record's, and the script holds nothing on it.
        \\local i = 0
        \\local hold = nil
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput(hold, 0) end
        \\end, emu.eventType.inputPolled)
        \\emu.addMemoryCallback(function()
        \\  i = i + 1
        \\  hold = KEYS[i + 1]
        \\  if i >= 2 then
        \\    local at = (i - 2) * RB
        \\    local attr = 0
        \\    for k = 0, 19 do
        \\      emu.write(at + k, emu.read(MAP + k * 2, vram), sram)
        \\      attr = attr | emu.read(MAP + k * 2 + 1, vram)
        \\    end
        \\    emu.write(at + 20, attr, sram)
        \\    emu.write(at + 21, emu.read(DH, wram), sram)
        \\    emu.write(at + 22, emu.read(DH + 1, wram), sram)
        \\    emu.write(at + 23, emu.read(DM, wram), sram)
        \\    emu.write(at + 24, emu.read(DM + 1, wram), sram)
        \\    emu.write(at + 25, emu.read(SH, wram), sram)
        \\    emu.write(at + 26, emu.read(H, wram), sram)
        \\    emu.write(at + 27, emu.read(CAMY, wram), sram)
        \\    emu.write(at + 28, emu.read(CAMX, wram), sram)
        \\    emu.write(at + 29, emu.read(SAMX, wram), sram)
        \\    emu.write(at + 30, emu.read(FC, wram), sram)
        \\    if i - 1 >= TICKS then emu.stop(0) end
        \\  end
        \\  if i == 1 then
        \\    for k = 0, 16 * 32 - 1 do emu.write(SLOTS + k, 0xFF, wram) end
        \\    emu.write(TOTAL, 0, wram)
        \\    emu.write(ACTIVE, 0, wram)
        \\    emu.write(OFFSCR, 0, wram)
        \\  end
        \\  local p = POKES[i - 1]
        \\  if p ~= nil then
        \\    for _, kv in ipairs(p) do emu.write(kv[1], kv[2], wram) end
        \\  end
        \\end, emu.callbackType.exec, COMMIT, COMMIT, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\local watchdog = 0
        \\emu.addEventCallback(function()
        \\  watchdog = watchdog + 1
        \\  if i == 0 and watchdog > 120 then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{});
}

pub const CartRun = struct {
    records: []Record,
    code: u8,

    pub fn deinit(self: *CartRun, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
    }
};

pub fn runCart(allocator: std.mem.Allocator, io: std.Io, cart: []const u8, s: Script, mesen_path: []const u8, home: []const u8) !CartRun {
    const stamped = try allocator.dupe(u8, cart);
    defer allocator.free(stamped);
    try snes_trace.stampSram(stamped);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".sfc", .data = stamped });

    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeLua(&lua.writer, s);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".lua", .data = lua.written() });

    const srm = try snes_trace.savePath(allocator, io, home, stem);
    defer allocator.free(srm);
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{ mesen_path, cart_name, "--testrunner", lua_name, "--timeout=60" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, srm, allocator, .limited(snes_trace.sram_bytes * 2)) catch
        return Error.NoSaveFile;
    defer allocator.free(bytes);
    if (bytes.len < @as(usize, s.ticks) * record_bytes) return Error.ShortSaveFile;

    const records = try allocator.alloc(Record, s.ticks);
    for (records, 0..) |*r, t| r.* = bytes[t * record_bytes ..][0..record_bytes].*;
    return .{ .records = records, .code = code };
}

/// The cart with `HudTens`' digit base one too high: every tens digit it draws
/// is the next digit's tile. Applied to the built cart's bytes, as
/// `enemy_oracle.blankAiRow` is.
pub fn faultDigit(cart: []u8) Error!void {
    const at = inject.symbolOffset("HudTens") orelse return Error.MissingSymbol;
    const want: u8 = @truncate(inject.symbol("ConstHudDigit") orelse return Error.MissingSymbol);
    if (!std.mem.eql(u8, cart[at..][0..16], inject.image[at..][0..16])) return Error.NotTheImage;
    for (0..15) |k| {
        // `adc.b #imm` is $69.
        if (cart[at + k] == 0x69 and cart[at + k + 1] == want) {
            cart[at + k + 1] = want + 1;
            return;
        }
    }
    return Error.MissingSymbol;
}

// ---- The comparison --------------------------------------------------------

/// Whether a tick's count cells are the scramble's: the timer was decremented
/// on it and landed below $80. Decided from the Game Boy's timer, which the
/// comparison also requires the cart's to equal.
pub fn scrambled(records: []const Record, tick: usize) bool {
    const now = records[tick][at_shuffle];
    const before: u8 = if (tick == 0) 0 else records[tick - 1][at_shuffle];
    return before != 0 and now < 0x80;
}

pub const Verdict = struct {
    ticks: usize,
    first_diff: ?usize = null,
    byte: usize = 0,
    /// Ticks whose count cells were masked, and on how many of them each
    /// machine's digits were not the count's own -- the scramble visibly drawn.
    masked: usize = 0,
    gb_scrambled: usize = 0,
    cart_scrambled: usize = 0,

    pub fn matched(self: Verdict) bool {
        return self.first_diff == null;
    }
};

fn countDigits(met: u8) [2]u8 {
    return .{ (met >> 4) + 0xA0, (met & 0x0F) + 0xA0 };
}

pub fn compare(gb: []const Record, cart: []const Record, met: u8) Verdict {
    var v: Verdict = .{ .ticks = @min(gb.len, cart.len) };
    const normal = countDigits(met);
    for (0..v.ticks) |t| {
        const mask = scrambled(gb, t);
        if (mask) {
            v.masked += 1;
            if (gb[t][18] != normal[0] or gb[t][19] != normal[1]) v.gb_scrambled += 1;
            if (cart[t][18] != normal[0] or cart[t][19] != normal[1]) v.cart_scrambled += 1;
        }
        for (0..record_bytes) |b| {
            if (mask and (b == count_cells[0] or b == count_cells[1])) continue;
            if (gb[t][b] != cart[t][b]) {
                v.first_diff = t;
                v.byte = b;
                return v;
            }
        }
    }
    return v;
}

pub const Report = struct {
    ticks: usize = 0,
    shuffle_at: u16 = 0,
    gb: []Record = &.{},
    cart: []Record = &.{},
    verdict: ?Verdict = null,
    fault: ?Verdict = null,
    code: u8 = 0,
    no_emulator: bool = false,
    /// Null when there is no recording to take one from, which is reported.
    trace: ?TraceReport = null,

    pub fn ok(self: Report) bool {
        if (self.no_emulator) return true;
        if (self.trace) |t| if (!t.ok()) return false;
        const v = self.verdict orelse return false;
        const f = self.fault orelse return false;
        return v.matched() and v.ticks == self.ticks and v.masked > 0 and
            v.gb_scrambled > 0 and v.cart_scrambled > 0 and !f.matched();
    }

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.gb);
        allocator.free(self.cart);
        if (self.trace) |t| allocator.free(t.cases);
    }
};

/// The count the scramble case sets, which is what the masked cells would
/// otherwise show.
const scramble_met: u8 = 0x47;

pub fn grade(allocator: std.mem.Allocator, io: std.Io, rom: []const u8, set: convert.Set, rec: ?gb_trace.Recording, mesen_path: []const u8, home: []const u8) !Report {
    const s = try script(allocator);
    defer s.deinit(allocator);
    var rep: Report = .{ .ticks = s.ticks, .shuffle_at = s.shuffle_at };

    var gb = try runGb(allocator, rom, s);
    defer gb.deinit(allocator);
    rep.gb = try allocator.dupe(Record, gb.records);
    errdefer allocator.free(rep.gb);

    if (mesen_path.len == 0) {
        rep.no_emulator = true;
        return rep;
    }

    var diag: inject.Diagnosis = .{};
    var cart = try inject.build(allocator, set, try cartBoot(allocator, rom, gb), &diag);
    defer cart.deinit();

    var honest = try runCart(allocator, io, cart.bytes, s, mesen_path, home);
    defer honest.deinit(allocator);
    rep.cart = try allocator.dupe(Record, honest.records);
    rep.code = honest.code;
    rep.verdict = compare(gb.records, honest.records, scramble_met);

    const faulted_bytes = try allocator.dupe(u8, cart.bytes);
    defer allocator.free(faulted_bytes);
    try faultDigit(faulted_bytes);
    var faulted = try runCart(allocator, io, faulted_bytes, s, mesen_path, home);
    defer faulted.deinit(allocator);
    rep.fault = compare(gb.records, faulted.records, scramble_met);

    if (rec) |r| rep.trace = try gradeTrace(allocator, io, rom, r, cart.bytes, mesen_path, home);
    return rep;
}

fn printRecord(out: *std.Io.Writer, r: Record) !void {
    for (r[0..status_tiles]) |b| try out.print("{X:0>2}", .{b});
    try out.print(" a{X:0>2} h{X:0>2}{X:0>2} m{X:0>2}{X:0>2} s{X:0>2} r{X:0>2} c{X:0>2}{X:0>2}", .{
        r[at_attr], r[at_disp_health + 1], r[at_disp_health], r[at_disp_missiles + 1], r[at_disp_missiles], r[at_shuffle], r[at_health], r[at_camera], r[at_camera + 1],
    });
    try out.print(" x{X:0>2} f{X:0>2}", .{ r[at_samus_x], r[at_counter] });
}

pub fn printReport(out: *std.Io.Writer, rep: Report, indent: []const u8) !void {
    if (rep.no_emulator) {
        try out.print("{s}{d} ticks on the Game Boy; not compared: no emulator (set MESEN)\n", .{ indent, rep.ticks });
        return;
    }
    const v = rep.verdict.?;
    const f = rep.fault.?;
    try out.print("{s}{d} of {d} ticks agree tile for tile{s}; the scramble drew {d} ticks ({d} and {d} visibly off the count); faulted cart {s}\n", .{
        indent,
        v.first_diff orelse v.ticks,
        rep.ticks,
        if (v.matched()) "" else " -- DIFFER",
        v.masked,
        v.gb_scrambled,
        v.cart_scrambled,
        if (f.matched()) "STILL AGREES" else "differs",
    });
    if (rep.trace) |t| {
        try printTrace(out, t, indent);
    } else {
        try out.print("{s}the recorded run: not taken -- no recording at {s}\n", .{ indent, gb_trace.recording_path });
    }
    if (v.first_diff) |d| {
        const lo = d -| 2;
        const hi = @min(v.ticks, d + 3);
        try out.print("{s}  byte {d}; tick  gb / cart: twenty tiles, attributes, displayed health and missiles, shuffle, real health\n", .{ indent, v.byte });
        for (lo..hi) |t| {
            try out.print("{s}  {d:>5}  ", .{ indent, t });
            try printRecord(out, rep.gb[t]);
            try out.print("\n{s}         ", .{indent});
            try printRecord(out, rep.cart[t]);
            try out.print("{s}\n", .{if (t == d) " <-" else ""});
        }
    }
}

// ---- A value set off the recorded run ---------------------------------------
//
// Every set above is chosen. These are not: Mesen2's Game Boy plays James's
// recording to a frame and hands back the window row it drew there with the
// bytes it drew it from, and the cart is seeded with those bytes and has to
// draw the same row. The machine that drew the reference is one this
// repository did not build, so this is the case that would catch the HUD
// oracle's own Game Boy and the port agreeing on something wrong.

/// Around three points of the recording: after the Missile Tank, after the
/// Energy Tank and the hundred frames its refill rolls up for, and after the
/// second Alpha. Several frames each, because a
/// frame is only usable when the row on screen was drawn from the bytes beside
/// it -- see `usable`.
pub const trace_targets = [_]u32{ 45100, 48600, 74000 };
pub const trace_span: u32 = 6;

/// Whether a traced frame's row is the status bar drawn from its own bytes: in
/// play, no pickup or door holding the bar back, the same bytes on the frame
/// before (so a frame that skipped the bar for a map row shows nothing stale),
/// and no scramble in the count.
pub fn usable(prev: gb_trace.HudFrame, h: gb_trace.HudFrame) bool {
    if (h.frame != prev.frame + 1) return false;
    if (h.get(0xFF9B) != 0x04) return false;
    if (h.get(0xD06C) != 0 or h.get(0xD06D) != 0 or h.get(0xD08E) != 0) return false;
    if (h.get(0xD096) != 0) return false;
    return std.mem.eql(u8, &prev.bytes, &h.bytes);
}

pub const TraceCase = struct { frame: u32, tanks: u8, health: u16, missiles: u16, met: u8, want: [status_tiles]u8, got: [status_tiles]u8 = @splat(0) };

pub const TraceReport = struct {
    cases: []TraceCase = &.{},
    /// Targets with no usable frame, which is a failure of the choice of
    /// target rather than of the port.
    missing: usize = 0,
    code: u8 = 0,

    pub fn ok(self: TraceReport) bool {
        if (self.missing != 0 or self.cases.len == 0) return false;
        for (self.cases) |c| if (!std.mem.eql(u8, &c.want, &c.got)) return false;
        return true;
    }
};

/// The recording, when it is here and was made on this cartridge. It is vendored
/// rather than downloadable, so its absence is a skip and not a failure.
pub fn loadRecording(allocator: std.mem.Allocator, io: std.Io, rom: []const u8) !?gb_trace.Recording {
    const mmo = std.Io.Dir.cwd().readFileAlloc(io, gb_trace.recording_path, allocator, .limited(64 << 20)) catch return null;
    const rec = try gb_trace.readRecording(allocator, mmo);
    rec.checkCartridge(rom) catch return null;
    return rec;
}

pub fn gradeTrace(allocator: std.mem.Allocator, io: std.Io, rom: []const u8, rec: gb_trace.Recording, cart: []const u8, mesen_path: []const u8, home: []const u8) !TraceReport {
    var frames: std.ArrayList(u32) = .empty;
    defer frames.deinit(allocator);
    for (trace_targets) |t| {
        for (0..trace_span) |k| try frames.append(allocator, t + @as(u32, @intCast(k)));
    }
    const huds = try gb_trace.runHud(allocator, io, rom, rec, frames.items, gb_trace.input_offset, mesen_path, home);
    defer allocator.free(huds);

    var rep: TraceReport = .{};
    var cases: std.ArrayList(TraceCase) = .empty;
    errdefer cases.deinit(allocator);
    for (trace_targets) |t| {
        var found = false;
        for (huds[1..], huds[0 .. huds.len - 1]) |h, prev| {
            if (h.frame < t or h.frame >= t + trace_span or !usable(prev, h)) continue;
            const word = struct {
                fn of(x: gb_trace.HudFrame, at: u16) u16 {
                    return @as(u16, x.get(at)) | (@as(u16, x.get(at + 1)) << 8);
                }
            };
            try cases.append(allocator, .{
                .frame = h.frame,
                .tanks = h.get(0xD050),
                .health = word.of(h, 0xD084),
                .missiles = word.of(h, 0xD086),
                .met = h.get(0xD09A),
                .want = h.tiles,
            });
            found = true;
            break;
        }
        if (!found) rep.missing += 1;
    }
    rep.cases = try cases.toOwnedSlice(allocator);

    // One tick of cart per case, held three: displayed and real both set to
    // the traced *displayed* counts, which are what the row was drawn from.
    var pokes: std.ArrayList(Poke) = .empty;
    defer pokes.deinit(allocator);
    for (rep.cases, 0..) |c, i| {
        try loadout(&pokes, allocator, @intCast(i * hold), c.tanks, c.health, c.missiles, c.met);
    }
    const ticks: u16 = @intCast(rep.cases.len * hold);
    if (ticks == 0) return rep;
    const keys = try allocator.alloc(oracle.Key, ticks);
    defer allocator.free(keys);
    @memset(keys, oracle.key.none);
    const s: Script = .{ .pokes = pokes.items, .keys = keys, .ticks = ticks, .shuffle_at = ticks };
    var run = try runCart(allocator, io, cart, s, mesen_path, home);
    defer run.deinit(allocator);
    rep.code = run.code;
    for (rep.cases, 0..) |*c, i| c.got = run.records[i * hold + hold - 1][0..status_tiles].*;
    return rep;
}

pub fn printTrace(out: *std.Io.Writer, rep: TraceReport, indent: []const u8) !void {
    try out.print("{s}the recorded run: {d} frame(s) off Mesen2's Game Boy{s}\n", .{
        indent, rep.cases.len, if (rep.missing != 0) " -- a target had no usable frame" else "",
    });
    for (rep.cases) |c| {
        const same = std.mem.eql(u8, &c.want, &c.got);
        try out.print("{s}  frame {d}: {d} tank(s), health {X:0>4}, missiles {X:0>4}, count {X:0>2}: ", .{ indent, c.frame, c.tanks, c.health, c.missiles, c.met });
        if (same) {
            try out.print("the cart draws the same row\n", .{});
        } else {
            try out.print("DIFFER\n{s}    gb   ", .{indent});
            for (c.want) |b| try out.print("{X:0>2}", .{b});
            try out.print("\n{s}    cart ", .{indent});
            for (c.got) |b| try out.print("{X:0>2}", .{b});
            try out.print("\n", .{});
        }
    }
}

// ---- The divider -----------------------------------------------------------

/// DIV at each of the scrambled arm's two reads, on one status-bar frame.
pub const DivSample = struct { frame: u64, tens: u8, ones: u8 };

const DivProbe = struct {
    m: *harness.Machine,
    out: []DivSample,
    n: usize = 0,

    fn hit(ctx: *anyopaque, bank: usize, pc: u16) void {
        const self: *DivProbe = @ptrCast(@alignCast(ctx));
        if (bank != 1 or self.n >= self.out.len) return;
        const div = self.m.sys.bus.read(gb_div);
        if (pc == scramble_tens_pc) {
            self.out[self.n] = .{ .frame = self.m.sys.frames, .tens = div, .ones = div };
        } else if (pc == scramble_ones_pc) {
            self.out[self.n].ones = div;
            self.n += 1;
        }
    }
};

/// Stand a new game still, start the scramble, and record DIV at both reads
/// for `out.len` status-bar frames. The measurement `!DIV_STEP` rests on.
pub fn measureDiv(allocator: std.mem.Allocator, rom: []const u8, out: []DivSample) !usize {
    var m = try standingGb(allocator, rom);
    defer m.deinit();
    var probe: DivProbe = .{ .m = &m, .out = out };
    m.exec = .{ .ctx = &probe, .hit = DivProbe.hit };
    defer m.exec = null;
    m.write(gb_shuffle, 0x7F);
    _ = try m.runFrames(out.len + 4, oracle.gbKeys(oracle.key.none));
    return probe.n;
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the divider advances $12.50 a frame at the scrambled arm, which is the engine's step" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    // At most $7F: `measureDiv` starts the timer there so every frame scrambles.
    var samples: [120]DivSample = undefined;
    const n = try measureDiv(testing.allocator, rom, &samples);
    try testing.expectEqual(samples.len, n);
    var thirteens: usize = 0;
    for (samples[1..], samples[0 .. samples.len - 1]) |s, p| {
        try testing.expectEqual(@as(u64, 1), s.frame - p.frame);
        const d = s.tens -% p.tens;
        try testing.expect(d == 0x12 or d == 0x13);
        thirteens += @intFromBool(d == 0x13);
        // The two reads a dozen instructions apart: the same count, or the next.
        try testing.expect(s.ones -% s.tens <= 1);
    }
    // 5/16 of the steps carry: 119 * 5 / 16 is 37.2.
    try testing.expect(thirteens >= 36 and thirteens <= 39);
    // 70224 CPU ticks a frame and a count every 256 is 274.3125 counts, which
    // in 8.8 fixed point is 70224; the divider is eight bits, so mod $10000.
    const step: u32 = @truncate(inject.symbol("ConstDivStep").?);
    try testing.expectEqual(@as(u32, 70224 % 0x10000), step);
}

test "the status bar's $FF cells are a character with nothing drawn in it" {
    // `LoadHud` leaves BG2's character $FF as the VRAM clear left it, on the
    // claim that `gfx_commonItems`' last tile -- id $FF under signed
    // addressing -- is all colour 0 in the cartridge.
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const e = offsets.find("gfx_commonItems").?;
    const tile = rom[e.romOffset()..e.romEnd()][e.size - 16 ..];
    for (tile) |b| try testing.expectEqual(@as(u8, 0), b);
    const base = offsets.find("hudBaseTilemap").?;
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, rom[base.romOffset()..base.romEnd()], &.{0xFF}));
}

test "the script never displays zero health and ends on a count the scramble leaves" {
    const s = try script(testing.allocator);
    defer s.deinit(testing.allocator);
    for (s.pokes) |p| {
        if (p.field == .disp_health_lo or p.field == .disp_health_hi) {
            var both: u16 = 0;
            for (s.pokes) |q| {
                if (q.tick != p.tick) continue;
                if (q.field == .disp_health_lo) both |= q.value;
                if (q.field == .disp_health_hi) both |= @as(u16, q.value) << 8;
            }
            try testing.expect(both != 0);
        }
    }
    try testing.expect(s.ticks > s.shuffle_at + shuffle_start);
    try testing.expect(@as(usize, s.ticks) * record_bytes <= snes_trace.sram_bytes);
}

test "a scrambled tick is one the timer was counted down on and landed below $80" {
    var r: [4]Record = @splat(@splat(0));
    r[0][at_shuffle] = 0x81;
    r[1][at_shuffle] = 0x80;
    r[2][at_shuffle] = 0x7F;
    r[3][at_shuffle] = 0x00;
    try testing.expect(!scrambled(&r, 1));
    try testing.expect(scrambled(&r, 2));
    try testing.expect(scrambled(&r, 3));
    // And the tick after zero draws the count again.
    var s: [2]Record = @splat(@splat(0));
    try testing.expect(!scrambled(&s, 1));
}
