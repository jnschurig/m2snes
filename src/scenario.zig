//! 1.0 Step 3: the `scenario` rung -- carts set up through the debug menu.
//!
//! A scenario boots the `--debug` cart into a new game, opens the menu with
//! its chord (L, R and Start), and drives it with the pad to a state. It checks
//! after every change, closes the menu, plays on, and checks again. Nothing is
//! poked: the setup goes through the menu's own input path, as a player's would
//! (the rule that fixtures do not force cart state).
//!
//! **Each scenario is its own Mesen2 run** with its own exit codes, and the
//! runs go in parallel. `snes boot` has spent most of its one-byte codes, and
//! one script that grew a check per scenario would reach Lua's 200-local limit,
//! which reads as a timeout (255) rather than an error. A failing run also
//! prints what it compared: the test runner passes Lua's `print` to stdout,
//! and the gate shows that line.
//!
//! **What is checked comes from the ROM**, not from the engine:
//! - the state before the menu: the new game's save record (`initial_save`),
//!   which is what a new game starts from;
//! - what an item row does: the `samusItems` bit its pickup routine sets, and a
//!   beam row the value its pickup writes, decoded from the routines that
//!   `handleItemPickup` (00:$372F) dispatches to;
//! - the ceilings: the fifth tank and the full `$99` from `pickup_energyTank`,
//!   and 999 missiles from `pickup_missileTank`.
//! The menu's own rules -- a count by ten, a row that takes a tank away -- are
//! the model below, written from the plan's C8, because the Game Boy has no
//! menu to ask.

const std = @import("std");
const items = @import("items.zig");
const save = @import("save.zig");
const inject = @import("snes_inject.zig");
const blocks = @import("blocks.zig");
const debug_tables = @import("debug_tables.zig");

// ---- What the ROM says ------------------------------------------------------

/// M2RoS's names for the variables the pickups write, as the routines address
/// them. What pins them is that the routines' bytes name them.
const samus_items: u16 = 0xD045;
const samus_active_weapon: u16 = 0xD04D;
const samus_energy_tanks: u16 = 0xD050;
const samus_cur_health_low: u16 = 0xD051;
const samus_beam: u16 = 0xD055;
const samus_max_missiles_low: u16 = 0xD081;
const samus_max_missiles_high: u16 = 0xD082;

/// `handleItemPickup`, where the search for its dispatch starts.
const handle_item_pickup: usize = 0x372F;

pub const Error = error{
    /// `ld a,b / dec a / rst $28` is not in `handleItemPickup`.
    NoDispatch,
    /// A pickup routine is not the shape the decode expects.
    UnexpectedPickup,
    /// The ROM holds no new-game record.
    NoInitialSave,
};

/// The menu's twelve SAMUS rows, in its order.
pub const Row = enum(u8) {
    bomb,
    hi_jump,
    screw,
    space,
    spring,
    spider,
    varia,
    beam,
    tanks,
    max_missiles,
    missiles,
    loadout,

    /// The pickup that sets each bit row's bit.
    fn pickup(r: Row) items.Collected {
        return switch (r) {
            .bomb => .bomb,
            .hi_jump => .high_jump,
            .screw => .screw_attack,
            .space => .space_jump,
            .spring => .spring_ball,
            .spider => .spider_ball,
            .varia => .varia,
            else => unreachable,
        };
    }
};
const bit_rows = 7;

/// What the pickup routines write, decoded from the ROM.
pub const Pickups = struct {
    /// The `samusItems` mask each bit row's pickup sets, in row order.
    bits: [bit_rows]u8,
    /// The beam each beam pickup writes: ice, wave, spazer, plasma.
    beams: [4]u8,
    /// `samusActiveWeapon` with missiles selected, which a beam pickup leaves.
    missile_weapon: u8,
    /// The tank count `pickup_energyTank` stops at, and the low byte of a
    /// full tank.
    tank_ceiling: u8,
    full_low: u8,
    /// The missile ceiling `pickup_missileTank` clamps to, BCD.
    missile_ceiling: u16,
};

/// The first run of `pattern` in `rom[from..to]`, a null in it matching any
/// byte.
fn find(rom: []const u8, from: usize, to: usize, pattern: []const ?u8) ?usize {
    var i = from;
    while (i + pattern.len <= @min(to, rom.len)) : (i += 1) {
        for (pattern, 0..) |p, k| {
            if (p) |b| if (rom[i + k] != b) break;
        } else return i;
    }
    return null;
}

fn lo(a: u16) u8 {
    return @truncate(a);
}
fn hi(a: u16) u8 {
    return @truncate(a >> 8);
}

/// The routine `handleItemPickup` jumps to for `c`: its jump table follows the
/// `rst $28`, one word per item, from `itemCollected` 1. Bank 0, so the address
/// is the file offset.
fn handler(rom: []const u8, c: items.Collected) Error!usize {
    const at = find(rom, handle_item_pickup, handle_item_pickup + 0x100, &.{ 0x78, 0x3D, 0xEF }) orelse return Error.NoDispatch;
    const e = at + 3 + (@as(usize, @intFromEnum(c)) - 1) * 2;
    return @as(usize, rom[e]) | @as(usize, rom[e + 1]) << 8;
}

pub fn pickups(rom: []const u8) Error!Pickups {
    var p: Pickups = undefined;
    // `ld a,[samusItems] / set n,a / ld [samusItems],a`. Varia's comes after
    // its wait for the fanfare, so each routine is searched, not read at its
    // start.
    for (0..bit_rows) |r| {
        const h = try handler(rom, @as(Row, @enumFromInt(r)).pickup());
        const at = find(rom, h, h + 0x80, &.{ 0xFA, lo(samus_items), hi(samus_items), 0xCB, null, 0xEA, lo(samus_items), hi(samus_items) }) orelse return Error.UnexpectedPickup;
        const op = rom[at + 4];
        if (op & 0xC7 != 0xC7) return Error.UnexpectedPickup; // `set n,a`
        p.bits[r] = @as(u8, 1) << @as(u3, @truncate(op >> 3));
    }
    // A beam's routine opens `ld a,n / ld [samusBeam],a`, and tests
    // `samusActiveWeapon` against missiles before it writes the weapon.
    for ([_]items.Collected{ .ice_beam, .wave_beam, .spazer, .plasma_beam }, 0..) |c, i| {
        const h = try handler(rom, c);
        if (find(rom, h, h + 5, &.{ 0x3E, null, 0xEA, lo(samus_beam), hi(samus_beam) }) != h) return Error.UnexpectedPickup;
        p.beams[i] = rom[h + 1];
        const cp = find(rom, h, h + 0x20, &.{ 0xFA, lo(samus_active_weapon), hi(samus_active_weapon), 0xFE, null }) orelse return Error.UnexpectedPickup;
        const m = rom[cp + 4];
        if (i > 0 and m != p.missile_weapon) return Error.UnexpectedPickup;
        p.missile_weapon = m;
    }
    {
        const h = try handler(rom, .energy_tank);
        const cp = find(rom, h, h + 0x20, &.{ 0xFA, lo(samus_energy_tanks), hi(samus_energy_tanks), 0xFE, null }) orelse return Error.UnexpectedPickup;
        p.tank_ceiling = rom[cp + 4];
        const full = find(rom, h, h + 0x20, &.{ 0x3E, null, 0xEA, lo(samus_cur_health_low), hi(samus_cur_health_low) }) orelse return Error.UnexpectedPickup;
        p.full_low = rom[full + 1];
    }
    {
        const h = try handler(rom, .missile_tank);
        const at = find(rom, h, h + 0x40, &.{ 0x3E, null, 0xEA, lo(samus_max_missiles_low), hi(samus_max_missiles_low), 0x3E, null, 0xEA, lo(samus_max_missiles_high), hi(samus_max_missiles_high) }) orelse return Error.UnexpectedPickup;
        p.missile_ceiling = @as(u16, rom[at + 6]) << 8 | rom[at + 1];
    }
    return p;
}

// ---- The model --------------------------------------------------------------

/// The variables the SAMUS page writes, which are the ones the game reads.
pub const Samus = struct {
    items: u8,
    beam: u8,
    weapon: u8,
    tanks: u8,
    /// BCD, the high byte in tanks.
    health: u16,
    max: u16,
    cur: u16,

    /// A new game's, from its save record. `loadGame_samusData` (00:$0CA3)
    /// sets the weapon to the saved beam.
    pub fn newGame(rom: []const u8) Error!Samus {
        const s = save.initial(rom) orelse return Error.NoInitialSave;
        return .{
            .items = s.items,
            .beam = s.beam,
            .weapon = s.beam,
            .tanks = s.energy_tanks,
            .health = s.health,
            .max = s.max_missiles,
            .cur = s.missiles,
        };
    }
};

pub const Key = enum { a, left, right };

/// One press on a SAMUS row. A switches a bit and runs the loadout, and on a
/// number is Right.
pub const Edit = struct { row: Row, key: Key = .a };

fn fromBcd(v: u16) u16 {
    return (v >> 8 & 0xF) * 100 + (v >> 4 & 0xF) * 10 + (v & 0xF);
}
fn toBcd(v: u16) u16 {
    return (v / 100) << 8 | (v / 10 % 10) << 4 | v % 10;
}

/// A count of missiles by ten, 0 to the ceiling.
fn byTen(v: u16, key: Key, ceiling: u16) u16 {
    const n = fromBcd(v);
    return toBcd(if (key == .left) n -| 10 else @min(n + 10, fromBcd(ceiling)));
}

pub fn apply(s: Samus, p: Pickups, rom_beam: u8, e: Edit) Samus {
    var n = s;
    const r = @intFromEnum(e.row);
    if (r < bit_rows) {
        const m = p.bits[r];
        n.items = switch (e.key) {
            .a => s.items ^ m,
            .right => s.items | m,
            .left => s.items & ~m,
        };
        return n;
    }
    switch (e.row) {
        .beam => {
            // The five in the ROM's order: the new game's, then the pickups'.
            const order = [5]u8{ rom_beam, p.beams[0], p.beams[1], p.beams[2], p.beams[3] };
            const i = std.mem.indexOfScalar(u8, &order, s.beam) orelse 0;
            const j = if (e.key == .left) (i + 4) % 5 else (i + 1) % 5;
            n.beam = order[j];
            if (s.weapon != p.missile_weapon) n.weapon = n.beam;
        },
        .tanks => if (e.key == .left) {
            // One fewer, and no more energy than the tanks hold.
            if (s.tanks > 0) {
                n.tanks = s.tanks - 1;
                if (n.tanks < s.health >> 8) n.health = @as(u16, n.tanks) << 8 | p.full_low;
            }
        } else {
            // `pickup_energyTank`: another up to the ceiling, and full.
            if (s.tanks < p.tank_ceiling) n.tanks = s.tanks + 1;
            n.health = @as(u16, n.tanks) << 8 | p.full_low;
        },
        .max_missiles => {
            n.max = byTen(s.max, e.key, p.missile_ceiling);
            n.cur = @min(s.cur, n.max);
        },
        .missiles => n.cur = byTen(s.cur, e.key, s.max),
        .loadout => if (e.key == .a) {
            for (p.bits) |m| n.items |= m;
            n.tanks = p.tank_ceiling;
            n.health = @as(u16, p.tank_ceiling) << 8 | p.full_low;
            n.max = p.missile_ceiling;
            n.cur = p.missile_ceiling;
        },
        else => unreachable,
    }
    return n;
}

// ---- The scenarios ----------------------------------------------------------

pub const Scenario = struct {
    name: []const u8,
    page: Page = .samus,
    /// The SAMUS page's edits.
    edits: []const Edit = &.{},
    /// Any other page's (1.0 Step 4).
    world: []const WorldEdit = &.{},
    /// After closing: the quake the kills armed starts and runs out.
    quake: bool = false,

    pub fn editCount(sc: Scenario) usize {
        return sc.edits.len + sc.world.len;
    }
};

pub const scenarios = [_]Scenario{
    // Each item on with A in turn; then Left, Right on a bit already on, and
    // A again, which switch rather than only set.
    .{ .name = "items", .edits = &.{
        .{ .row = .bomb },   .{ .row = .hi_jump },                .{ .row = .screw },
        .{ .row = .space },  .{ .row = .spring },                 .{ .row = .spider },
        .{ .row = .varia },  .{ .row = .spider, .key = .left },   .{ .row = .bomb, .key = .right },
        .{ .row = .varia },
    } },
    // Right through all four and round to the power beam, Left round the
    // other way.
    .{ .name = "beams", .edits = &.{
        .{ .row = .beam, .key = .right }, .{ .row = .beam, .key = .right },
        .{ .row = .beam, .key = .right }, .{ .row = .beam, .key = .right },
        .{ .row = .beam, .key = .right }, .{ .row = .beam, .key = .left },
        .{ .row = .beam },
    } },
    // Two tanks and one back; the ceiling and the count by ten, the count held
    // under the ceiling both ways.
    .{ .name = "counts", .edits = &.{
        .{ .row = .tanks, .key = .right },        .{ .row = .tanks, .key = .right },
        .{ .row = .tanks, .key = .left },         .{ .row = .max_missiles, .key = .right },
        .{ .row = .missiles, .key = .right },     .{ .row = .missiles, .key = .right },
        .{ .row = .max_missiles, .key = .left },  .{ .row = .max_missiles, .key = .left },
        .{ .row = .missiles, .key = .left },      .{ .row = .missiles },
    } },
    // Everything, then the fifth tank's Right, which fills as the pickup does,
    // and one taken away.
    .{ .name = "loadout", .edits = &.{
        .{ .row = .loadout },
        .{ .row = .tanks, .key = .right },
        .{ .row = .tanks, .key = .left },
        .{ .row = .loadout, .key = .left },
    } },
    // Step 4. Bank A's first Alpha killed, left alone by Right, revived by
    // Left and killed again; then four more, three of them in the bank that
    // is loaded. Five kills leave $42, two thresholds, and the quake runs once
    // the menu is closed. Named by record since the page took playthrough
    // order (1.0 Step 26).
    .{ .name = "metroids", .page = .metroids, .quake = true, .world = &.{
        .{ .row = met(0xA, 0x40) }, .{ .row = met(0xA, 0x40), .key = .right }, .{ .row = met(0xA, 0x40), .key = .left },
        .{ .row = met(0xA, 0x40) }, .{ .row = met(0xF, 0x40) },                .{ .row = met(0xF, 0x43) },
        .{ .row = met(0xF, 0x41) }, .{ .row = met(0xE, 0x48) },
    } },
    // Bank 9's first orb, in a bank not loaded, switched, set and reset; then
    // the baby, the last row and the one in the loaded bank.
    .{ .name = "flags", .page = .flags, .world = &.{
        .{ .row = 0 },                .{ .row = 0 },               .{ .row = 0, .key = .right },
        .{ .row = 0, .key = .right }, .{ .row = 0, .key = .left }, .{ .row = 51 },
        .{ .row = 51, .key = .left }, .{ .row = 51, .key = .right },
    } },
    // 1.0 Step 10: larvae, which the status bar's count leaves out until the
    // stinger runs (02:$6B8E), so killing and reviving them moves only the
    // real count: $D:$00's and $D:$10's killed, $D:$00's revived; then bank
    // A's first Alpha, which moves both. Before the step all 46 killed took
    // the shown $39 to $93.
    .{ .name = "larvae", .page = .metroids, .world = &.{
        .{ .row = met(0xD, 0x47) }, .{ .row = met(0xD, 0x40), .key = .right }, .{ .row = met(0xD, 0x47), .key = .left },
        .{ .row = met(0xA, 0x40) },
    } },
    // Hours up three and down past 00 to 99 and back; minutes down past 00
    // to 59 and up past 59 to 00.
    .{ .name = "clock", .page = .clock, .world = &.{
        .{ .row = 0, .key = .right }, .{ .row = 0, .key = .right }, .{ .row = 0 },
        .{ .row = 0, .key = .left },  .{ .row = 0, .key = .left },  .{ .row = 0, .key = .left },
        .{ .row = 0, .key = .left },  .{ .row = 0, .key = .right }, .{ .row = 1, .key = .left },
        .{ .row = 1, .key = .right }, .{ .row = 1 },
    } },
};

// ---- The world pages (1.0 Step 4) ---------------------------------------------

/// A root row of the menu and the page it opens, in the menu's order.
pub const Page = enum {
    samus,
    metroids,
    flags,
    clock,

    pub fn rootRow(p: Page) u8 {
        return @intFromEnum(p);
    }
    /// `!DebugPage` once it is open.
    pub fn id(p: Page) u8 {
        return switch (p) {
            .samus => 1,
            .metroids => 3,
            .flags => 4,
            .clock => 5,
        };
    }
};

/// One press on a METROIDS, FLAGS or CLOCK row: a list entry, or hours (0)
/// and minutes (1).
pub const WorldEdit = struct { row: u8, key: Key = .a };

/// A METROIDS row by its record: the page's order is the playthrough's.
fn met(comptime bank: u8, comptime number: u8) u8 {
    return debug_tables.rowOf(bank, number);
}

/// What a kill does, read out of the ROM: `.death` (02:$6D61) and
/// `earthquakeCheck` (08:$7EBC).
pub const Kill = struct {
    /// 02:$6D79 `LD A,$02`, written to the fight flag and at $6D7E the slot's
    /// spawn flag: dead.
    dead: u8,
    /// 02:$6D90, the status bar's shuffle.
    shuffle: u8,
    /// 08:$7ECD, 08:$7ED5 and 08:$7ED8: the ticks a threshold arms, the count
    /// that is only the Queen, and her ticks.
    ticks: u8,
    last_count: u8,
    ticks_last: u8,
    /// 08:$7EDE, through its `$FF`.
    thresholds: [16]u8,
    threshold_count: usize,

    pub fn read(rom: []const u8) !Kill {
        var k: Kill = .{
            .dead = try blocks.loadIn(rom, 2, 0x6D79),
            .shuffle = try blocks.loadIn(rom, 2, 0x6D90),
            .ticks = try blocks.loadIn(rom, 8, 0x7ECD),
            .last_count = try blocks.compareIn(rom, 8, 0x7ED5),
            .ticks_last = try blocks.loadIn(rom, 8, 0x7ED8),
            .thresholds = undefined,
            .threshold_count = 0,
        };
        const o = blocks.offsetIn(8, 0x7EBC);
        if (rom[o] != 0x21) return Error.UnexpectedPickup; // `LD HL,d16`
        const t = blocks.offsetIn(8, @as(u16, rom[o + 1]) | @as(u16, rom[o + 2]) << 8);
        while (rom[t + k.threshold_count] != 0xFF) : (k.threshold_count += 1) {
            k.thresholds[k.threshold_count] = rom[t + k.threshold_count];
        }
        return k;
    }

    fn isThreshold(k: Kill, count: u8) bool {
        return std.mem.indexOfScalar(u8, k.thresholds[0..k.threshold_count], count) != null;
    }
};

/// A never-loaded spawn flag: 00:$0243 fills $C500-$CAFF with it at power-on.
pub const flag_new: u8 = 0xFF;

fn bcdAdd(v: u8, up: bool) u8 {
    const n: u16 = @as(u16, v >> 4) * 10 + (v & 0xF);
    const m: u16 = if (up) (n + 1) % 100 else (n + 99) % 100;
    return @intCast((m / 10) << 4 | m % 10);
}

/// A saved-half flag the scenario watches: one list entry's.
pub const Flag = struct { bank: u8, number: u8 };

/// The variables the world pages write. `shuffle` and `quake_next` are the
/// kill's; a new game has not set them, so they are not checked until a kill.
/// The shuffle is the status bar's, which counts it down in NMI a frame at a
/// time with the menu up as with it down, so it is checked only on the kill's
/// own step, and with the frames since the press as slack.
pub const WorldState = struct {
    real: u8,
    disp: u8,
    shuffle: ?u8 = null,
    quake_next: ?u8 = null,
    hours: u8,
    minutes: u8,
    flags: [max_flags]u8 = @splat(flag_new),

    pub const max_flags = 8;

    pub fn newGame(rom: []const u8) Error!WorldState {
        const s = save.initial(rom) orelse return Error.NoInitialSave;
        return .{ .real = s.metroid_count_real, .disp = s.metroid_count_displayed, .hours = s.hours, .minutes = s.minutes };
    }
};

/// The entries a list scenario edits, and where they are in the model.
pub const Watch = struct {
    list: []const Flag,
    fn index(w: Watch, f: Flag) usize {
        for (w.list, 0..) |g, i| if (g.bank == f.bank and g.number == f.number) return i;
        unreachable;
    }
};

/// `unshown`: a METROIDS row the status bar's count does not show yet, a larva
/// before `enAI_metroidStinger` has run (`debug_tables.larvae`). No scenario
/// runs the stinger, so every larva is one.
pub fn applyWorld(s: WorldState, k: Kill, page: Page, entry: ?Flag, unshown: bool, w: Watch, e: WorldEdit) WorldState {
    var n = s;
    n.shuffle = null;
    switch (page) {
        .metroids => {
            const i = w.index(entry.?);
            const dead = s.flags[i] == k.dead;
            const kill = switch (e.key) {
                .a => !dead,
                .right => true,
                .left => false,
            };
            if (kill and !dead) {
                n.flags[i] = k.dead;
                n.real = bcdAdd(s.real, false);
                if (!unshown) n.disp = bcdAdd(s.disp, false);
                n.shuffle = k.shuffle;
                if (k.isThreshold(n.real)) n.quake_next = if (n.real == k.last_count) k.ticks_last else k.ticks;
            } else if (!kill and dead) {
                n.flags[i] = flag_new;
                n.real = bcdAdd(s.real, true);
                if (!unshown) n.disp = bcdAdd(s.disp, true);
            }
        },
        .flags => {
            const i = w.index(entry.?);
            n.flags[i] = switch (e.key) {
                .a => if (s.flags[i] == k.dead) flag_new else k.dead,
                .right => k.dead,
                .left => flag_new,
            };
        },
        .clock => if (e.row == 0) {
            n.hours = bcdAdd(s.hours, e.key != .left);
        } else {
            const m = bcdAdd(s.minutes, e.key != .left);
            n.minutes = if (m == 0x99) 0x59 else if (m == 0x60) 0x00 else m;
        },
        .samus => unreachable,
    }
    return n;
}

// ---- The script -------------------------------------------------------------

/// Exit codes, the same for every scenario; 10 + k is edit k's check.
pub fn code(c: u8) []const u8 {
    return switch (c) {
        0 => "every check held",
        1 => "Fatal ran",
        2 => "the new game, play, or the end of the run never arrived",
        3 => "the chord did not open the menu at its root, or A did not open SAMUS",
        4 => "the engine was handed a pose it could not run",
        5 => "B twice did not close the menu back to play",
        6 => "the new game's Samus is not its save record's",
        7 => "a second of play after closing, Samus is not what the menu left",
        8 => "the quake the kills armed did not run",
        255 => "the emulator did not exit normally",
        else => if (c >= 10) "an edit's check disagreed with the ROM" else "an unknown code: a timeout, or a script error, reads as one",
    };
}

const frames_apart = 8;

fn sym(name: []const u8) !u32 {
    return inject.symbol(name) orelse error.MissingSymbol;
}

fn writeSamus(w: *std.Io.Writer, s: Samus) !void {
    try w.print("{{ {d}, {d}, {d}, {d}, {d}, {d}, {d} }}", .{ s.items, s.beam, s.weapon, s.tanks, s.health, s.max, s.cur });
}

pub fn writeLua(gpa: std.mem.Allocator, rom: []const u8, sc: Scenario, w: *std.Io.Writer) !void {
    if (sc.page != .samus) return writeWorldLua(gpa, rom, sc, w);
    const p = try pickups(rom);
    const start = try Samus.newGame(rom);

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The `{s}` scenario, 1.0 Step 3: the `--debug` cart as a new game,
        \\-- set up through the debug menu's own input and checked after every
        \\-- change against the ROM's new-game record and pickup routines
        \\-- (`src/scenario.zig`). Then closed, a second of play, and checked again.
        \\--
        \\-- Exit codes: 0 every check held; 1 Fatal ran; 2 the new game, play or
        \\-- the end never arrived; 3 the chord or A did not open the menu; 4 an
        \\-- unrunnable pose; 5 B twice did not close it; 6 the new game's Samus
        \\-- is not its record's; 7 after a second of play Samus is not what the
        \\-- menu left; 10 + k edit k's check. A failure prints what it compared.
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr) return emu.read(addr, wram) | (emu.read(addr + 1, wram) << 8) end
        \\local R = {{ frames = {d}, unhandled = {d}, countdown = {d}, open = {d}, page = {d}, paused = {d},
        \\  items = {d}, beam = {d}, weapon = {d}, tanks = {d}, health = {d}, max = {d}, cur = {d} }}
        \\local APART = {d}
        \\
    , .{
        sc.name,
        try sym("VarFrameCount"), try sym("VarUnhandled"),  try sym("VarCountdown"),
        try sym("VarDebugOpen"),  try sym("VarDebugPage"),  try sym("VarPaused"),
        try sym("VarItems"),      try sym("VarBeam"),       try sym("VarActiveWeapon"),
        try sym("VarTanks"),      try sym("VarHealthLo"),   try sym("VarMaxMissLo"),
        try sym("VarCurMissLo"),  frames_apart,
    });

    // The presses, one every `APART` frames: the chord, A for SAMUS, then per
    // edit Down to its row and the edit's key, then B twice. A step's check is
    // 0 for none, "open", "page", "closed", or the edit's number, whose want is
    // WANT[k + 1]; WANT[1] is the new game.
    try w.print("WANT = {{\n  ", .{});
    try writeSamus(w, start);
    var s = start;
    for (sc.edits) |e| {
        s = apply(s, p, start.beam, e);
        try w.print(",\n  ", .{});
        try writeSamus(w, s);
    }
    try w.print("\n}}\nLABEL = {{", .{});
    for (sc.edits) |e| try w.print(" \"{s} {s}\",", .{ @tagName(e.row), @tagName(e.key) });
    try w.print(" }}\nSTEPS = {{\n  {{ \"chord\", \"open\" }}, {{ \"a\", \"page\" }},\n", .{});
    var row: u8 = 0;
    for (sc.edits, 1..) |e, k| {
        while (row != @intFromEnum(e.row)) : (row = if (row < @intFromEnum(e.row)) row + 1 else row - 1) {
            try w.print("  {{ \"{s}\", 0 }},\n", .{if (row < @intFromEnum(e.row)) "down" else "up"});
        }
        try w.print("  {{ \"{s}\", {d} }},\n", .{ @tagName(e.key), k });
    }
    try w.print("  {{ \"b\", 0 }}, {{ \"b\", \"closed\" }},\n}}\n", .{});

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
        \\local NAMES = {{ "items", "beam", "weapon", "tanks", "health", "max", "cur" }}
        \\local function samus()
        \\  return {{ emu.read(R.items, wram), emu.read(R.beam, wram), emu.read(R.weapon, wram),
        \\    emu.read(R.tanks, wram), rd16(R.health), rd16(R.max), rd16(R.cur) }}
        \\end
        \\local function expect(c, label, want)
        \\  local got = samus()
        \\  for i = 1, #NAMES do
        \\    if got[i] ~= want[i] then
        \\      fail(c, string.format("%s: %s %04x, wanted %04x", label, NAMES[i], got[i], want[i]))
        \\      return
        \\    end
        \\  end
        \\end
        \\
        \\-- The step a tick presses on, and the one it checks at: pressed on
        \\-- two frames, checked five after.
        \\local FIRST = 10
        \\local function stepAt(t, off)
        \\  local i = t - FIRST - off
        \\  if i < 0 or i % APART ~= 0 then return nil end
        \\  return i // APART + 1
        \\end
        \\local PADS = {{ chord = {{ l = true, r = true, start = true }} }}
        \\
        \\emu.addEventCallback(function()
        \\  if stopped then return end
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(1, "Fatal") end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(4, "unhandled pose " .. emu.read(R.unhandled, wram)) end
        \\  if frames > 3000 then fail(2, "phase " .. phase .. " at frame " .. frames) end
        \\  if phase == 0 and rd16(R.frames) ~= 0 then phase = 1 end
        \\  -- The appearance: the countdown starts, and play is when it ends.
        \\  if phase == 2 and rd16(R.countdown) ~= 0 then phase = 3 end
        \\  if phase == 3 and rd16(R.countdown) == 0 then
        \\    phase, tick = 4, 0
        \\    expect(6, "the new game", WANT[1])
        \\  end
        \\  if phase ~= 4 then return end
        \\  tick = tick + 1
        \\  local k = stepAt(tick, 5)
        \\  if k ~= nil and k <= #STEPS then
        \\    local c = STEPS[k][2]
        \\    if c == "open" then
        \\      if emu.read(R.open, wram) == 0 or emu.read(R.page, wram) ~= 0 then fail(3, "the chord: no menu at its root") end
        \\    elseif c == "page" then
        \\      if emu.read(R.page, wram) ~= 1 then fail(3, "A: page " .. emu.read(R.page, wram) .. ", wanted SAMUS") end
        \\    elseif c == "closed" then
        \\      if emu.read(R.open, wram) ~= 0 or emu.read(R.paused, wram) ~= 0 then fail(5, "B twice: the menu up or paused") end
        \\    elseif c ~= 0 then
        \\      expect(10 + c, "edit " .. c .. " (" .. LABEL[c] .. ")", WANT[c + 1])
        \\    end
        \\  end
        \\  -- A second of play after the last step, and Samus as the menu left her.
        \\  if tick == FIRST + #STEPS * APART + 60 then
        \\    expect(7, "a second after closing", WANT[#WANT])
        \\    if emu.read(R.open, wram) ~= 0 then fail(5, "the menu came back") end
        \\    if not stopped then emu.stop(0) end
        \\  end
        \\end, emu.eventType.endFrame)
        \\
        \\-- The pad. On the title, Start for a new game on the frames the title
        \\-- rung places it; in play, each step's key on its two frames.
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
        \\    local key = STEPS[k][1]
        \\    p = PADS[key] or {{ [key] = true }}
        \\  end
        \\  emu.setInput(p, 0)
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

/// The list a list page shows, from the blob the cart carries.
fn listEntries(a: std.mem.Allocator, rom: []const u8, page: Page) ![]const u8 {
    return switch (page) {
        .metroids => try debug_tables.metroidsBlob(a, rom),
        .flags => try debug_tables.flagsBlob(a, rom),
        else => unreachable,
    };
}

fn entryFlag(blob: []const u8, row: u8) Flag {
    const e = blob[1 + @as(usize, row) * debug_tables.entry_bytes ..];
    return .{ .bank = e[0], .number = e[2] };
}

fn wram(addr: u32) u32 {
    return addr & 0x1FFFF;
}

/// One check's wants, in `PROBES` order: the counts, the kill's two, the
/// clock, and each watched flag's save-buffer byte and, in the loaded bank,
/// its live one. -1 is not checked. A second after closing, the kill's two
/// are not checked: the status bar and the quake count them down.
fn writeWant(w: *std.Io.Writer, s: WorldState, flags: usize, live: []const bool, after: bool) !void {
    const shuffle: i32 = if (after or s.shuffle == null) -1 else s.shuffle.?;
    const quake: i32 = if (after or s.quake_next == null) -1 else s.quake_next.?;
    try w.print("{{ {d}, {d}, {d}, {d}, {d}, {d}", .{ s.real, s.disp, shuffle, quake, s.hours, s.minutes });
    for (0..flags) |i| {
        try w.print(", {d}", .{s.flags[i]});
        if (live[i]) try w.print(", {d}", .{s.flags[i]});
    }
    try w.print(" }}", .{});
}

/// A METROIDS, FLAGS or CLOCK scenario (1.0 Step 4): the same boot, chord and
/// pad as the SAMUS ones, checked against `applyWorld`'s model of the ROM.
fn writeWorldLua(gpa: std.mem.Allocator, rom: []const u8, sc: Scenario, w: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const k = try Kill.read(rom);
    const start = try WorldState.newGame(rom);
    const level = (save.initial(rom) orelse return Error.NoInitialSave).level_bank;
    const larvae = try debug_tables.larvae(a, rom);

    // The rows, and the flags they touch.
    const blob: ?[]const u8 = if (sc.page == .metroids or sc.page == .flags) try listEntries(a, rom, sc.page) else null;
    const rows: u8 = if (blob) |b| b[0] else 2;
    var watch: [WorldState.max_flags]Flag = undefined;
    var watched: usize = 0;
    for (sc.world) |e| {
        if (e.row >= rows) return error.RowOutOfRange;
        const b = blob orelse continue;
        const f = entryFlag(b, e.row);
        for (watch[0..watched]) |g| {
            if (g.bank == f.bank and g.number == f.number) break;
        } else {
            watch[watched] = f;
            watched += 1;
        }
    }
    const wl: Watch = .{ .list = watch[0..watched] };
    var live: [WorldState.max_flags]bool = @splat(false);
    for (watch[0..watched], 0..) |f, i| live[i] = f.bank == level;

    const save_buf = wram(try sym("VarSpawnSaveBuf"));
    const spawn = wram(try sym("VarSpawnFlags"));
    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The `{s}` scenario, 1.0 Step 4: the `--debug` cart as a new game, set up
        \\-- through the debug menu's {s} page and checked after every change against
        \\-- the ROM: the new game's record, and what `.death` (02:$6D61) and
        \\-- `earthquakeCheck` (08:$7EBC) do to the counts, the flag and the quake
        \\-- (`src/scenario.zig`). Then closed, a second of play, and checked again.
        \\--
        \\-- Exit codes as the SAMUS scenarios', and 8 the quake the kills armed did
        \\-- not start and run out.
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr) return emu.read(addr, wram) | (emu.read(addr + 1, wram) << 8) end
        \\local R = {{ frames = {d}, unhandled = {d}, countdown = {d}, open = {d}, page = {d}, paused = {d},
        \\  quakeTimer = {d} }}
        \\local APART, PAGE, LIMIT, QUAKE = {d}, {d}, {d}, {s}
        \\PROBES = {{
        \\  {{ "real", {d} }}, {{ "disp", {d} }}, {{ "shuffle", {d}, APART }}, {{ "quakeNext", {d} }},
        \\  {{ "hours", {d} }}, {{ "minutes", {d} }},
        \\
    , .{
        sc.name,                  @tagName(sc.page),
        try sym("VarFrameCount"), try sym("VarUnhandled"),
        try sym("VarCountdown"),  try sym("VarDebugOpen"),
        try sym("VarDebugPage"),  try sym("VarPaused"),
        try sym("VarQuakeTimer"), frames_apart,
        sc.page.id(),             @as(u32, if (sc.quake) 5000 else 3000),
        if (sc.quake) "true" else "false",
        try sym("VarMetReal"),    try sym("VarMetDisp"),
        try sym("VarShuffle"),    try sym("VarQuakeNext"),
        try sym("VarIgtHours"),   try sym("VarIgtMinutes"),
    });
    for (watch[0..watched], 0..) |f, i| {
        const off = (@as(u32, f.bank) - 9) * 0x40 + (@as(u32, f.number) - debug_tables.saved_first);
        try w.print("  {{ \"{X}:{X:0>2} saved\", {d} }},\n", .{ f.bank, f.number, save_buf + off });
        if (live[i]) try w.print("  {{ \"{X}:{X:0>2} live\", {d} }},\n", .{ f.bank, f.number, spawn + f.number });
    }

    // The steps: the chord, Down to the page's root row and A, then per edit
    // the shortest way round to its row and its key, then B twice.
    try w.print("}}\nWANT = {{\n  ", .{});
    try writeWant(w, start, watched, &live, false);
    var st = start;
    for (sc.world) |e| {
        const f: ?Flag = if (blob) |b| entryFlag(b, e.row) else null;
        const unshown = sc.page == .metroids and larvae.larval[e.row];
        st = applyWorld(st, k, sc.page, f, unshown, wl, e);
        try w.print(",\n  ", .{});
        try writeWant(w, st, watched, &live, false);
    }
    // A quake the edits armed must be queued for the frames after closing.
    if (sc.quake and st.quake_next == null) return error.NoQuakeArmed;
    try w.print("\n}}\nAFTER = ", .{});
    try writeWant(w, st, watched, &live, true);
    try w.print("\nLABEL = {{", .{});
    for (sc.world) |e| try w.print(" \"row {d} {s}\",", .{ e.row, @tagName(e.key) });
    try w.print(" }}\nSTEPS = {{\n  {{ \"chord\", \"open\" }},\n", .{});
    for (0..sc.page.rootRow()) |_| try w.print("  {{ \"down\", 0 }},\n", .{});
    try w.print("  {{ \"a\", \"page\" }},\n", .{});
    var row: u8 = 0;
    for (sc.world, 1..) |e, i| {
        const down = (@as(u16, e.row) + rows - row) % rows;
        const up = (@as(u16, row) + rows - e.row) % rows;
        if (down <= up) {
            for (0..down) |_| try w.print("  {{ \"down\", 0 }},\n", .{});
        } else for (0..up) |_| try w.print("  {{ \"up\", 0 }},\n", .{});
        row = e.row;
        try w.print("  {{ \"{s}\", {d} }},\n", .{ @tagName(e.key), i });
    }
    try w.print("  {{ \"b\", 0 }}, {{ \"b\", \"closed\" }},\n}}\n", .{});

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
        \\-- A probe with slack may be that many below its want, and no more.
        \\local function expect(c, label, want)
        \\  for i, p in ipairs(PROBES) do
        \\    local got = emu.read(p[2], wram)
        \\    local slack = p[3] or 0
        \\    if want[i] >= 0 and (got > want[i] or got < want[i] - slack) then
        \\      fail(c, string.format("%s: %s %02x, wanted %02x", label, p[1], got, want[i]))
        \\      return
        \\    end
        \\  end
        \\end
        \\
        \\local FIRST = 10
        \\local function stepAt(t, off)
        \\  local i = t - FIRST - off
        \\  if i < 0 or i % APART ~= 0 then return nil end
        \\  return i // APART + 1
        \\end
        \\local PADS = {{ chord = {{ l = true, r = true, start = true }} }}
        \\local DONE = FIRST + #STEPS * APART + 60
        \\local quake = {{ stage = 0, at = 0 }}
        \\
        \\emu.addEventCallback(function()
        \\  if stopped then return end
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(1, "Fatal") end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(4, "unhandled pose " .. emu.read(R.unhandled, wram)) end
        \\  if frames > LIMIT then fail(2, "phase " .. phase .. " at frame " .. frames .. ", quake stage " .. quake.stage) end
        \\  if phase == 0 and rd16(R.frames) ~= 0 then phase = 1 end
        \\  if phase == 2 and rd16(R.countdown) ~= 0 then phase = 3 end
        \\  if phase == 3 and rd16(R.countdown) == 0 then
        \\    phase, tick = 4, 0
        \\    expect(6, "the new game", WANT[1])
        \\  end
        \\  if phase ~= 4 then return end
        \\  tick = tick + 1
        \\  local k = stepAt(tick, 5)
        \\  if k ~= nil and k <= #STEPS then
        \\    local c = STEPS[k][2]
        \\    if c == "open" then
        \\      if emu.read(R.open, wram) == 0 or emu.read(R.page, wram) ~= 0 then fail(3, "the chord: no menu at its root") end
        \\    elseif c == "page" then
        \\      if emu.read(R.page, wram) ~= PAGE then fail(3, "A: page " .. emu.read(R.page, wram) .. ", wanted " .. PAGE) end
        \\    elseif c == "closed" then
        \\      if emu.read(R.open, wram) ~= 0 or emu.read(R.paused, wram) ~= 0 then fail(5, "B twice: the menu up or paused") end
        \\    elseif c ~= 0 then
        \\      expect(10 + c, "edit " .. c .. " (" .. LABEL[c] .. ")", WANT[c + 1])
        \\    end
        \\  end
        \\  if tick == DONE then
        \\    expect(7, "a second after closing", AFTER)
        \\    if emu.read(R.open, wram) ~= 0 then fail(5, "the menu came back") end
        \\    if not QUAKE and not stopped then emu.stop(0) end
        \\    quake.stage, quake.at = 1, tick
        \\  end
        \\  if tick <= DONE or not QUAKE then return end
        \\  -- The quake the kills armed: it starts within its ticks of 256 frames,
        \\  -- the first a counter wrap away, and runs out.
        \\  local since = tick - quake.at
        \\  if quake.stage == 1 then
        \\    if emu.read(R.quakeTimer, wram) ~= 0 then quake.stage, quake.at = 2, tick
        \\    elseif since > 256 * 5 then fail(8, "no quake " .. since .. " frames after closing") end
        \\  elseif quake.stage == 2 then
        \\    if emu.read(R.quakeTimer, wram) == 0 then
        \\      if not stopped then emu.stop(0) end
        \\    elseif since > 800 then fail(8, "the quake still running " .. since .. " frames on") end
        \\  end
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
        \\  local p = {{}}
        \\  local k = stepAt(tick, 0) or stepAt(tick, 1)
        \\  if k ~= nil and k <= #STEPS then
        \\    local key = STEPS[k][1]
        \\    p = PADS[key] or {{ [key] = true }}
        \\  end
        \\  emu.setInput(p, 0)
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the pickups' bits are M2RoS's item bits, decoded from the routines" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const p = try pickups(rom);
    const want = [bit_rows]u3{ items.bit_bomb, items.bit_hi_jump, items.bit_screw, items.bit_space, items.bit_spring, items.bit_spider, items.bit_varia };
    for (want, p.bits) |b, m| try testing.expectEqual(@as(u8, 1) << b, m);
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, p.beams);
    try testing.expectEqual(@as(u8, 8), p.missile_weapon);
    try testing.expectEqual(@as(u8, 5), p.tank_ceiling);
    try testing.expectEqual(@as(u8, 0x99), p.full_low);
    try testing.expectEqual(@as(u16, 0x0999), p.missile_ceiling);
}

test "a pickup routine of another shape is refused, not read" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    // Hi-jump's `set 1,a` made `res 1,a`: the decode must not take a bit
    // from it.
    const h = try handler(rom, .high_jump);
    const at = find(rom, h, h + 0x80, &.{ 0xFA, 0x45, 0xD0, 0xCB }).?;
    const bad = try testing.allocator.dupe(u8, rom);
    defer testing.allocator.free(bad);
    bad[at + 4] = 0x8F;
    try testing.expectError(Error.UnexpectedPickup, pickups(bad));
}

test "the model: bits switch, beams wrap, counts clamp" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const p = try pickups(rom);
    const s0 = try Samus.newGame(rom);
    try testing.expectEqual(@as(u8, 0), s0.items);
    try testing.expectEqual(@as(u16, 0x30), s0.max);

    var s = apply(s0, p, s0.beam, .{ .row = .hi_jump });
    try testing.expectEqual(@as(u8, 0x02), s.items);
    s = apply(s, p, s0.beam, .{ .row = .hi_jump });
    try testing.expectEqual(@as(u8, 0x00), s.items);

    s = apply(s0, p, s0.beam, .{ .row = .beam, .key = .left });
    try testing.expectEqual(@as(u8, 4), s.beam);
    try testing.expectEqual(@as(u8, 4), s.weapon);

    s = apply(s0, p, s0.beam, .{ .row = .missiles, .key = .right });
    try testing.expectEqual(s0.max, s.cur);
    s = apply(s0, p, s0.beam, .{ .row = .max_missiles, .key = .left });
    try testing.expectEqual(@as(u16, 0x20), s.max);
    try testing.expectEqual(@as(u16, 0x20), s.cur);

    s = apply(s0, p, s0.beam, .{ .row = .loadout });
    try testing.expectEqual(@as(u8, 0x7F), s.items);
    try testing.expectEqual(@as(u16, 0x0599), s.health);
    s.health = 0x0310;
    s = apply(s, p, s0.beam, .{ .row = .tanks, .key = .right });
    try testing.expectEqual(@as(u8, 5), s.tanks);
    try testing.expectEqual(@as(u16, 0x0599), s.health);
}

test "every scenario's script is written" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    for (scenarios) |sc| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeLua(testing.allocator, rom, sc, &out.writer);
        try testing.expect(std.mem.indexOf(u8, out.written(), "STEPS") != null);
    }
}
