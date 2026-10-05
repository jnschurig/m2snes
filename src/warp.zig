//! 1.0 Step 5 (C8c): how the debug menu's WARP page arrives at each of Step 1's
//! destinations.
//!
//! `roster.destinations` says where each destination is. This says how to get
//! there with the room *loaded*: the graphics, the metatile and collision
//! tables, the solidity row, the damage, the song and the item slot a player
//! walking in would have. Those are what the door scripts leave behind.
//!
//! **A chain** is one or two real door scripts, by index. Run in order at the
//! live Metroid count (the cart and the Game Boy both do), they leave the loaded
//! state of a player arriving through the second: the first loads the tileset
//! of the room that door is walked from, the second is the door. A door that
//! loads a whole tileset of its own is a chain alone.
//!
//! **The ROM alone does not say which tileset about half the rooms have.** A
//! door that loads only an enemy page (most Metroid rooms) or only a lava table
//! keeps the rest of whatever the room it leaves had, and a scroll-blocked edge
//! is not a door unless Samus can walk through it. So the chains come from the
//! door crawl (`crawl.zig`): our Game Boy walks Samus through every door and
//! records what loaded (`WalkedDoor`), and a chain is kept only if running it
//! leaves what the engine left. Where the crawl never entered a destination's
//! room, the static reading stands in (`Inference`: the door graph where it
//! settles the room, `screens.assign` otherwise), and the entry says so.
//!
//! **The standing spot** is where Samus is put in the destination cell: the
//! nearest place to the destination's point (the station, the orb, the
//! Metroid, the door) where both of her probe columns are clear of anything
//! solid or hurtful from her head down, with a floor under one of them, read
//! through the tables the chain leaves loaded.

const std = @import("std");
const offsets = @import("offsets.zig");
const map = @import("map.zig");
const door = @import("door.zig");
const screens = @import("screens.zig");
const save = @import("save.zig");
const roster = @import("roster.zig");

pub const Error = error{ NoDoorData, NoInitialSave, UnknownTable, Unreached };

// ---- The loaded state -------------------------------------------------------

pub const Src = struct {
    bank: u8,
    addr: u16,

    pub fn eql(a: Src, b: Src) bool {
        return a.bank == b.bank and a.addr == b.addr;
    }
};

/// A `COPY` whose source and destination are both kept: the eight scripts that
/// carry one copy something other than a tileset's page.
pub const Copy = struct { which: door.Copy, src: Src, dest: u16, len: u16 };

/// Everything a door script leaves loaded that the room is drawn or played
/// with. `data` is the last `COPY_data`, which is what the eight scripts that
/// carry one use to put a block of tiles somewhere a `LOAD` does not.
pub const State = struct {
    bg: Src,
    spr: Src,
    tiletable: u4,
    collision: u4,
    /// The row's three thresholds, not its index: the new game's record holds
    /// $64 for all three, which is no row of the table.
    solidity: [3]u8,
    acid: u8,
    spike: u8,
    song: u4,
    item: ?u4 = null,
    data: ?Copy = null,

    pub fn eql(a: State, b: State) bool {
        return std.meta.eql(a, b);
    }
};

/// Which of `State`'s components an op writes: one bit each, in field order.
pub const Writes = u16;
pub const w_bg: Writes = 1 << 0;
pub const w_spr: Writes = 1 << 1;
pub const w_tiletable: Writes = 1 << 2;
pub const w_collision: Writes = 1 << 3;
pub const w_solidity: Writes = 1 << 4;
pub const w_damage: Writes = 1 << 5;
pub const w_song: Writes = 1 << 6;
pub const w_item: Writes = 1 << 7;
pub const w_data: Writes = 1 << 8;

/// Apply one op; returns the components it wrote. `rows` is
/// `solidity_thresholds`, four bytes a row.
pub fn apply(s: *State, op: door.Op, rows: []const u8) Writes {
    switch (op) {
        .load => |l| switch (l.which) {
            .bg => {
                s.bg = .{ .bank = l.src_bank, .addr = l.src_addr };
                return w_bg;
            },
            .spr => {
                s.spr = .{ .bank = l.src_bank, .addr = l.src_addr };
                return w_spr;
            },
        },
        .copy => |c| {
            s.data = .{ .which = c.which, .src = .{ .bank = c.src_bank, .addr = c.src_addr }, .dest = c.dest, .len = c.len };
            return w_data;
        },
        .tiletable => |v| {
            s.tiletable = v;
            return w_tiletable;
        },
        .collision => |v| {
            s.collision = v;
            return w_collision;
        },
        .solidity => |v| {
            s.solidity = rows[@as(usize, v) * 4 ..][0..3].*;
            return w_solidity;
        },
        .damage => |d| {
            s.acid = d.acid;
            s.spike = d.spike;
            return w_damage;
        },
        .song => |v| {
            s.song = v;
            return w_song;
        },
        .item => |v| {
            s.item = v;
            return w_item;
        },
        else => return 0,
    }
}

fn indexOfPointer(rom: []const u8, table: []const u8, ptr: u16) ?u4 {
    const e = offsets.find(table) orelse return null;
    const t = rom[e.romOffset()..e.romEnd()];
    var i: usize = 0;
    while (i + 1 < t.len) : (i += 2) {
        if (std.mem.readInt(u16, t[i..][0..2], .little) == ptr) return @intCast(i / 2);
    }
    return null;
}

/// The collision table a `COLLISION` operand selects: through the ROM's
/// `collision_pointers`, as 00:$2859 reads it. Not `roster.collisionFor`,
/// which pairs a *metatile* table with its collision table by name: the two
/// orders differ.
pub fn collisionTable(rom: []const u8, operand: u4) ?[]const u8 {
    const p = offsets.find("collision_pointers") orelse return null;
    if (@as(usize, operand) * 2 + 2 > p.size) return null;
    const addr = std.mem.readInt(u16, rom[p.romOffset() + @as(usize, operand) * 2 ..][0..2], .little);
    if (addr < 0x4000 or addr + 0x100 > 0x8000) return null;
    return rom[@as(usize, p.bank) * offsets.bank_size + (addr - 0x4000) ..][0..0x100];
}

pub fn thresholds(rom: []const u8) []const u8 {
    const e = offsets.find("solidity_thresholds").?;
    return rom[e.romOffset()..e.romEnd()];
}

/// The bank a `LOAD_spr` names for an enemy page: the save buffer keeps only
/// the address (`$D808`), because every enemy page is in one bank. Read off
/// the scripts, not assumed: the first `LOAD_spr` of that address.
fn sprBank(decoded: door.Decoded, addr: u16) ?u8 {
    for (decoded.ops.items) |op| switch (op) {
        .load => |l| if (l.which == .spr and l.src_addr == addr) return l.src_bank,
        else => {},
    };
    return null;
}

/// The loaded state a new game starts in: the record's `$D808`-`$D814` block
/// and its damage and song, turned back into the operands that would write
/// them. The item slot is the common set's; no `ITEM` has run.
pub fn initialState(rom: []const u8, decoded: door.Decoded) !State {
    const init = save.initial(rom) orelse return Error.NoInitialSave;
    return .{
        .bg = .{ .bank = init.bg_gfx_bank, .addr = init.bg_gfx_src },
        .spr = .{ .bank = sprBank(decoded, init.enemy_gfx_src) orelse return Error.UnknownTable, .addr = init.enemy_gfx_src },
        .tiletable = indexOfPointer(rom, "metatile_pointers", init.tiletable_src) orelse return Error.UnknownTable,
        .collision = indexOfPointer(rom, "collision_pointers", init.collision_src) orelse return Error.UnknownTable,
        .solidity = .{ init.samus_solidity, init.enemy_solidity, init.beam_solidity },
        .acid = init.acid_damage,
        .spike = init.spike_damage,
        .song = @truncate(init.room_song),
    };
}

// ---- Crossings, one run each ------------------------------------------------

/// One way a crossing can go: the scripts that run, in order (a script, or a
/// script and the one its `IF_MET_LESS` branches to), where it lands, and what
/// the Metroid count must be for it to go this way.
pub const Run = struct {
    scripts: [2]u16,
    n: u2,
    to: roster.Place,
    queen: bool,
    /// Set when the run takes, or passes over, an `IF_MET_LESS`.
    counted: bool,
};

/// The runs of door `index` crossed out of `from` going `dir`. A branch is
/// followed into its target script as a separate run, and the fall-through
/// past it continues the first.
fn runs(
    decoded: door.Decoded,
    ptrs: []const u8,
    index: u16,
    past: roster.Place,
    out: *std.ArrayList(Run),
    allocator: std.mem.Allocator,
) !void {
    if (index == 0) {
        try out.append(allocator, .{ .scripts = .{ 0, 0 }, .n = 0, .to = past, .queen = false, .counted = false });
        return;
    }
    const ops = screens.scriptOps(decoded, ptrs, index) orelse return;
    var counted = false;
    var landed = false;
    for (ops) |op| switch (op) {
        .if_met_less => |m| {
            counted = true;
            const sub = screens.scriptOps(decoded, ptrs, m.transition) orelse continue;
            var to: roster.Place = past;
            var queen = false;
            for (sub) |o| switch (o) {
                .warp => |w| to = .{ .bank = w.bank, .cell = w.pos },
                .enter_queen => |q| {
                    to = roster.queenCell(q);
                    queen = true;
                },
                else => {},
            };
            try out.append(allocator, .{ .scripts = .{ index, m.transition }, .n = 2, .to = to, .queen = queen, .counted = true });
        },
        .warp => |w| {
            try out.append(allocator, .{ .scripts = .{ index, 0 }, .n = 1, .to = .{ .bank = w.bank, .cell = w.pos }, .queen = false, .counted = counted });
            landed = true;
        },
        .enter_queen => |q| {
            try out.append(allocator, .{ .scripts = .{ index, 0 }, .n = 1, .to = roster.queenCell(q), .queen = true, .counted = counted });
            landed = true;
        },
        else => {},
    };
    if (!landed) try out.append(allocator, .{ .scripts = .{ index, 0 }, .n = 1, .to = past, .queen = false, .counted = counted });
}

/// Every crossing's runs, with the target rule `roster.world` uses: a `WARP`
/// onto a blank cell goes one cell on in the crossing's direction.
pub const Crossing = struct { from: roster.Place, dir: roster.Dir, run: Run };

pub fn crossings(allocator: std.mem.Allocator, rom: []const u8, w: roster.World, decoded: door.Decoded) ![]Crossing {
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    var out: std.ArrayList(Crossing) = .empty;
    errdefer out.deinit(allocator);
    var rs: std.ArrayList(Run) = .empty;
    defer rs.deinit(allocator);
    for (0..map.bank_count) |bi| {
        const bank: u8 = map.first_bank + @as(u8, @intCast(bi));
        for (w.banks[bi].cells, 0..) |c, ci| {
            if (!c.inUse()) continue;
            const index = roster.doorIndex(c.transition);
            for ([_]roster.Dir{ .right, .left, .up, .down }) |d| {
                if (!d.blocks(c.scroll)) continue;
                const past: roster.Place = .{ .bank = bank, .cell = d.step(@intCast(ci)).? };
                rs.clearRetainingCapacity();
                try runs(decoded, ptrs, index, past, &rs, allocator);
                for (rs.items) |r0| {
                    var r = r0;
                    if (!r.queen and r.to.bank >= map.first_bank and r.to.bank <= map.last_bank and !w.cellOf(r.to).inUse()) {
                        const n = d.step(r.to.cell).?;
                        if (w.cellOf(.{ .bank = r.to.bank, .cell = n }).inUse()) r.to.cell = n;
                    }
                    try out.append(allocator, .{ .from = .{ .bank = bank, .cell = @intCast(ci) }, .dir = d, .run = r });
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- Openings ---------------------------------------------------------------

/// A cell's screen body: 16 rows of 16 metatile ids.
pub fn body(rom: []const u8, w: roster.World, p: roster.Place) ?[]const u8 {
    const off = w.cellOf(p).screenOffsetInBank() orelse return null;
    return rom[@as(usize, p.bank) * offsets.bank_size + off ..][0..map.screen_bytes];
}

/// Whether a metatile lets Samus through: all four of its tiles at or above
/// the threshold, since a tile is solid to her when its id is below it
/// (`cp [samusSolidityIndex]`, `SampleTile`).
fn open(mts: []const u8, m: u8, solid: u8) bool {
    return openThrough(mts, null, m, solid);
}

/// The collision bits of a block a beam or a bomb destroys: in the way until
/// a player clears it, and no wall.
pub const block_shot: u8 = 0x20;
pub const block_bomb: u8 = 0x40;

/// `open`, counting a destructible tile as open when `coll` is given.
fn openThrough(mts: []const u8, coll: ?[]const u8, m: u8, solid: u8) bool {
    const at = @as(usize, m) * 4;
    if (at + 4 > mts.len) return false;
    for (mts[at..][0..4]) |t| {
        if (t >= solid) continue;
        if (coll) |cl| if (cl[t] & (block_shot | block_bomb) != 0) continue;
        return false;
    }
    return true;
}

/// The metatile at edge position `i` of a screen, on the side a crossing in
/// `dir` leaves by (`leaving`) or enters by.
fn edgeAt(b: []const u8, dir: roster.Dir, leaving: bool, i: usize) u8 {
    const side: roster.Dir = if (leaving) dir else switch (dir) {
        .right => .left,
        .left => .right,
        .up => .down,
        .down => .up,
    };
    return switch (side) {
        .right => b[i * map.grid_w + (map.grid_w - 1)],
        .left => b[i * map.grid_w],
        .down => b[(map.grid_w - 1) * map.grid_w + i],
        .up => b[i],
    };
}

/// Whether a crossing has an opening: some position along the shared edge
/// open on both sides, the leaving side read with what was loaded before the
/// script and the entering side with what it leaves.
pub fn opening(rom: []const u8, w: roster.World, from: roster.Place, to: roster.Place, dir: roster.Dir, before: State, then: State) bool {
    const a = body(rom, w, from) orelse return false;
    const b = body(rom, w, to) orelse return false;
    const ma = screens.metatileTable(rom, before.tiletable) orelse return false;
    const mb = screens.metatileTable(rom, then.tiletable) orelse return false;
    for (0..map.grid_w) |i| {
        if (open(ma, edgeAt(a, dir, true, i), before.solidity[0]) and open(mb, edgeAt(b, dir, false, i), then.solidity[0])) return true;
    }
    return false;
}

/// Whether the side a crossing in `dir` enters `p` by has an opening under
/// `t`, destructible blocks counted as open.
pub fn enteringOpen(rom: []const u8, w: roster.World, p: roster.Place, dir: roster.Dir, t: Tileset) bool {
    const b = body(rom, w, p) orelse return false;
    const mts = screens.metatileTable(rom, t.tiletable) orelse return false;
    const coll = collisionTable(rom, t.collision) orelse return false;
    for (0..map.grid_w) |i| if (openThrough(mts, coll, edgeAt(b, dir, false, i), t.solidity[0])) return true;
    return false;
}

// ---- What a room is drawn with ----------------------------------------------

/// The part of the loaded state a room is drawn and stood in with: the
/// background page, and the metatile, collision and solidity tables.
pub const Tileset = struct {
    bg: Src,
    tiletable: u4,
    collision: u4,
    solidity: [3]u8,

    pub fn of(s: State) Tileset {
        return .{ .bg = s.bg, .tiletable = s.tiletable, .collision = s.collision, .solidity = s.solidity };
    }

    pub fn eql(a: Tileset, b: Tileset) bool {
        return std.meta.eql(a, b);
    }
};

/// The four writes a script must make to load a whole tileset.
pub const w_tileset: Writes = w_bg | w_tiletable | w_collision | w_solidity;

/// What a run leaves after `before`, and what it wrote. A branch's own
/// `IF_MET_LESS` is where the first script stops.
fn after(decoded: door.Decoded, ptrs: []const u8, rows: []const u8, before: State, r: Run) struct { State, Writes } {
    var s = before;
    var wr: Writes = 0;
    for (r.scripts[0..r.n]) |si| {
        const ops = screens.scriptOps(decoded, ptrs, si) orelse continue;
        for (ops) |op| {
            if (op == .if_met_less) break;
            wr |= apply(&s, op, rows);
        }
    }
    return .{ s, wr };
}

/// The new game's `metroidCountReal`: what a chain is built and checked at.
/// The cart and the Game Boy both run it at the live count.
pub const start_count: u8 = 0x47;

/// Run script `index` the way `StepDoorScript` does at Metroid count
/// `count`: an `IF_MET_LESS` whose operand is at or above the count jumps to
/// its script (`cmp !MetReal` / `bcs`, 00:$254A), and the rest is skipped.
pub fn runScript(decoded: door.Decoded, ptrs: []const u8, rows: []const u8, before: State, index: u16, count: u8) struct { State, Writes } {
    var s = before;
    var wr: Writes = 0;
    var at = index;
    var hops: usize = 0;
    outer: while (hops < 8) : (hops += 1) {
        const ops = screens.scriptOps(decoded, ptrs, at) orelse break;
        for (ops) |op| {
            if (op == .if_met_less and op.if_met_less.met_count >= count) {
                at = op.if_met_less.transition;
                continue :outer;
            }
            wr |= apply(&s, op, rows);
        }
        break;
    }
    return .{ s, wr };
}

fn runChain(decoded: door.Decoded, ptrs: []const u8, rows: []const u8, before: State, chain: []const u16) State {
    var s = before;
    for (chain) |i| s, _ = runScript(decoded, ptrs, rows, s, i, start_count);
    return s;
}

/// Per room, every tileset it can be arrived in with: from the new game's,
/// across every crossing that has an opening and does not test the count,
/// to a fixed point. A room whose set has one member is **settled** by the
/// door graph; one with more is not, because some door into it loads no
/// tileset and the rooms it can be entered from differ.
pub const Settled = struct {
    sets: []std.AutoArrayHashMapUnmanaged(Tileset, void),

    pub fn deinit(self: *Settled, allocator: std.mem.Allocator) void {
        for (self.sets) |*x| x.deinit(allocator);
        allocator.free(self.sets);
    }

    pub fn one(self: Settled, room: u16) ?Tileset {
        if (room >= self.sets.len or self.sets[room].count() != 1) return null;
        return self.sets[room].keys()[0];
    }
};

pub fn settle(allocator: std.mem.Allocator, rom: []const u8, w: roster.World, decoded: door.Decoded, xs: []const Crossing) !Settled {
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    const rows = thresholds(rom);
    var rooms: usize = 0;
    for (w.room) |b| for (b) |r| {
        if (r != roster.World.none) rooms = @max(rooms, @as(usize, r) + 1);
    };
    const sets = try allocator.alloc(std.AutoArrayHashMapUnmanaged(Tileset, void), rooms);
    for (sets) |*x| x.* = .empty;
    var out: Settled = .{ .sets = sets };
    errdefer out.deinit(allocator);

    const init = save.initial(rom) orelse return Error.NoInitialSave;
    const s0 = try initialState(rom, decoded);
    try sets[w.roomOf(.{ .bank = init.level_bank, .cell = init.cell() })].put(allocator, Tileset.of(s0), {});

    var changed = true;
    while (changed) {
        changed = false;
        for (xs) |x| {
            if (x.run.counted or x.run.queen) continue;
            if (x.run.to.bank < map.first_bank or x.run.to.bank > map.last_bank) continue;
            if (!w.cellOf(x.run.to).inUse()) continue;
            const from = w.roomOf(x.from);
            const to = w.roomOf(x.run.to);
            if (from == to) continue;
            var i: usize = 0;
            while (i < sets[from].count()) : (i += 1) {
                const t = sets[from].keys()[i];
                var before = s0;
                before.bg = t.bg;
                before.tiletable = t.tiletable;
                before.collision = t.collision;
                before.solidity = t.solidity;
                const s, _ = after(decoded, ptrs, rows, before, x.run);
                if (!opening(rom, w, x.from, x.run.to, x.dir, before, s)) continue;
                const g = try sets[to].getOrPut(allocator, Tileset.of(s));
                if (!g.found_existing) changed = true;
            }
        }
    }
    return out;
}

// ---- The warp entries -------------------------------------------------------

/// Where an entry's tileset came from.
pub const Basis = enum {
    /// Our Game Boy walked through the chain's door into the room, from a
    /// room it had walked into from the new game (or through a door that
    /// loads a whole tileset of its own): what loads is the engine's.
    walked,
    /// Walked through, but from a room the crawl seeded from the static
    /// reading: the door's own writes are the engine's, the rest inferred.
    seeded,
    /// Never walked into: the static reading (door graph, else
    /// `screens.assign`) alone.
    inferred,
    /// Held to the recording (1.0 Step 18f): the table the 100% recording's
    /// Game Boy showed the first time it stood in the cell, at that count,
    /// where the walked or static chain left another.
    recorded,
};

/// One door the crawl (`crawl.zig`) walked Samus through: where from and
/// what was loaded there, and where to and what the door left loaded.
pub const WalkedDoor = struct {
    from: roster.Place,
    from_room: u16,
    from_truth: bool,
    from_block: [block_len]u8,
    dir: roster.Dir,
    count: u8,
    door: u16,
    to: roster.Place,
    to_room: u16,
    to_truth: bool,
    to_block: [block_len]u8,
};

/// `$D808`-`$D814`, what a save keeps of the loaded state.
pub const block_len: usize = 13;

/// A saved block as a `Tileset`, through the ROM's own pointer tables.
pub fn tilesetOfBlock(rom: []const u8, block: [block_len]u8) ?Tileset {
    const tt = indexOfPointer(rom, "metatile_pointers", std.mem.readInt(u16, block[5..7], .little)) orelse return null;
    const co = indexOfPointer(rom, "collision_pointers", std.mem.readInt(u16, block[7..9], .little)) orelse return null;
    return .{
        .bg = .{ .bank = block[2], .addr = std.mem.readInt(u16, block[3..5], .little) },
        .tiletable = tt,
        .collision = co,
        .solidity = block[10..13].*,
    };
}

pub const max_chain = 2;

pub const Entry = struct {
    dest: roster.Destination,
    /// The scripts the warp runs, in order: the one that loads the room's
    /// tileset, then the door into the room. One when the door loads it.
    chain: [max_chain]u16,
    n: u8,
    basis: Basis,
    /// Set when the static reading names a different metatile table for the
    /// cell than the chain leaves: a finding about the static reading (and
    /// so about `screens.assign`, which draws the port's boots), not an error.
    disagrees: bool,
    tileset: Tileset,
    /// The Metroid count `tileset` is what the chain leaves at: the new
    /// game's, but for a destination the crawl only walked into at a lower
    /// count (the Queen's door). The warp runs the chain at the live count.
    count: u8,
    /// Where Samus is put, and the camera, as world positions (screen in the
    /// high byte's low nibble, pixel in the low byte).
    samus_y: u16,
    samus_x: u16,
    cam_y: u16,
    cam_x: u16,
    /// Only a ball fits at the spot (an item in a tunnel): she arrives as one.
    morph: bool = false,
    /// Cleared for a `doors` entry whose cell has no standing spot under what
    /// it loads (1.0 Step 18a): she is put in the middle, and neither where
    /// she arrives nor whether she stands is graded, only what was loaded.
    stand: bool = true,
};

/// The door that runs `ENTER_QUEEN`, and the op. The ROM has one ($19D), which
/// door $13B's `IF_MET_LESS` branch runs; `basis` is `.walked` for it because it
/// loads every part of a tileset itself, as a crawl-walked door that does is.
pub fn queenDoor(decoded: door.Decoded, ptrs: []const u8) ?struct { index: u16, op: @FieldType(door.Op, "enter_queen") } {
    var i: u16 = 0;
    while (i < ptrs.len / 2) : (i += 1) {
        const ops = screens.scriptOps(decoded, ptrs, i) orelse continue;
        for (ops) |op| switch (op) {
            .enter_queen => |q| return .{ .index = i, .op = q },
            else => {},
        };
    }
    return null;
}

/// The room a destination is in. A few spawn records sit in cells drawn with
/// the shared blank screen, which the door graph gives no room; such a cell is
/// in the room of the neighbour it scrolls into.
pub fn roomAt(w: roster.World, p: roster.Place) u16 {
    const r = w.roomOf(p);
    if (r != roster.World.none) return r;
    for ([_]roster.Dir{ .right, .left, .up, .down }) |d| {
        const n = w.roomOf(.{ .bank = p.bank, .cell = d.step(p.cell).? });
        if (n != roster.World.none) return n;
    }
    return roster.World.none;
}

/// The script that loads `t`, lowest index first: every one of its four
/// writes made, and made to `t`.
fn loaderFor(decoded: door.Decoded, ptrs: []const u8, rows: []const u8, s0: State, t: Tileset) ?u16 {
    return loaderMatching(decoded, ptrs, rows, s0, t, false, null) orelse
        loaderMatching(decoded, ptrs, rows, s0, t, true, null);
}

/// A script that loads the whole of `t` from the new game's state and warps,
/// into map bank `bank` when one is named. **A script that tests the count is
/// taken only when `gated` is set** (1.0 Step 14), and then it is run at the
/// new game's count, as a chain is built and checked, following its branch:
/// the lava caves' rooms are loaded only by such scripts, so without them
/// the truth arrival into Metroid 01's room had no chain and a seeded guess
/// drew the room in another area's rock. The Queen's three ops stay out.
fn loaderMatching(decoded: door.Decoded, ptrs: []const u8, rows: []const u8, s0: State, t: Tileset, gated: bool, bank: ?u4) ?u16 {
    for (1..door.pointer_count) |i| {
        const ops = screens.scriptOps(decoded, ptrs, i) orelse continue;
        var counted = false;
        var queen = false;
        var warps = false;
        for (ops) |op| switch (op) {
            .if_met_less => counted = true,
            .warp => warps = true,
            .enter_queen, .exit_queen, .escape_queen => queen = true,
            else => {},
        };
        if (queen or (counted and !gated) or !warps) continue;
        if (bank) |bk| if (warpBank(decoded, ptrs, @intCast(i), start_count) != bk) continue;
        const s, const wr = runScript(decoded, ptrs, rows, s0, @intCast(i), start_count);
        if (wr & w_tileset == w_tileset and Tileset.of(s).eql(t)) return @intCast(i);
    }
    return null;
}

/// The map bank script `index`'s `WARP` enters at `count`, following its
/// branches as `runScript` does.
fn warpBank(decoded: door.Decoded, ptrs: []const u8, index: u16, count: u8) ?u4 {
    var at = index;
    var hops: usize = 0;
    var to: ?u4 = null;
    outer: while (hops < 8) : (hops += 1) {
        const ops = screens.scriptOps(decoded, ptrs, at) orelse break;
        for (ops) |op| switch (op) {
            .if_met_less => |x| if (x.met_count >= count) {
                at = x.transition;
                continue :outer;
            },
            .warp => |x| to = x.bank,
            else => {},
        };
        break;
    }
    return to;
}

// ---- Where Samus stands -----------------------------------------------------

/// The collision byte's bits a standing spot must keep clear of: spikes and
/// acid anywhere she is, and a floor that is only a ceiling.
const block_down: u8 = 0x04;
const block_spike: u8 = 0x08;
const block_acid: u8 = 0x10;

/// Samus's probes, as `CollideBottom` and `CollideTop` take them off her
/// position, with the OAM offsets that cancel on the way in and out already
/// cancelled: the feet at y+$1C, the standing head at y-8, and the two columns
/// at x+4 and x+12.
pub const feet: u16 = 0x1C;
pub const head: u16 = 8;
pub const probe_left: u16 = 4;
pub const probe_right: u16 = 12;

/// The camera a still Samus leaves where it is. `HandleCamera` moves it only
/// with her speed, or a pixel a frame back inside a clamp on a blocked edge,
/// so any guide inside the bands holds; these put her mid-band. X: the guide
/// is x - camera + $60 and the band $40-$70. Y: y - camera + $60 against
/// `GUIDE_UP_OPEN` $4E and `GUIDE_DOWN_OPEN` $50.
pub const cam_from_samus_x: u16 = 0x60 - 0x58;
pub const cam_from_samus_y: u16 = 0x60 - 0x4F;
pub const clamp_left: u16 = 0x50;
pub const clamp_right: u16 = 0xB0;
pub const clamp_up: u16 = 0x48;
pub const clamp_down: u16 = 0xC0;

const Grid = struct {
    ids: [32][32]u8,
    coll: []const u8,
    solid: u8,
    /// Count destructible tiles as cleared: the crawl clears them before it
    /// walks, as a player would have.
    through: bool = false,
    /// Only spots inside a room's reach (1.0 Step 18f).
    within: ?Within = null,

    fn tile(g: Grid, r: usize, c: usize) u8 {
        return g.ids[r][c];
    }
    fn isSolid(g: Grid, r: usize, c: usize) bool {
        if (g.through and g.coll[g.ids[r][c]] & (block_shot | block_bomb) != 0) return false;
        return g.ids[r][c] < g.solid;
    }
    fn hurts(g: Grid, r: usize, c: usize) bool {
        return g.coll[g.ids[r][c]] & (block_spike | block_acid) != 0;
    }
    fn floor(g: Grid, r: usize, c: usize) bool {
        return g.isSolid(r, c) and g.coll[g.ids[r][c]] & block_down == 0 and !g.hurts(r, c);
    }
    fn clear(g: Grid, r: usize, c: usize) bool {
        return !g.isSolid(r, c) and !g.hurts(r, c);
    }
};

fn grid(rom: []const u8, b: []const u8, t: Tileset) ?Grid {
    const mts = screens.metatileTable(rom, t.tiletable) orelse return null;
    const coll = collisionTable(rom, t.collision) orelse return null;
    var g: Grid = .{ .ids = undefined, .coll = coll, .solid = t.solidity[0] };
    for (0..32) |r| for (0..32) |c| {
        const m = @as(usize, b[(r / 2) * map.grid_w + c / 2]) * 4;
        g.ids[r][c] = if (m + 4 <= mts.len) mts[m + (r % 2) * 2 + (c % 2)] else 0;
    };
    return g;
}

/// `morph`: only a ball fits there, and she is put in it as one.
pub const Spot = struct { y: u8, x: u8, morph: bool = false };

/// The standing spot nearest `(py, px)`, pixels within the cell: both probe
/// columns clear of anything solid or hurtful from the head down, and a floor
/// under at least one of them. Null when the cell has none.
pub fn standingSpot(rom: []const u8, b: []const u8, t: Tileset, py: u16, px: u16) ?Spot {
    return standingSpotThrough(rom, b, t, py, px, false);
}

/// `standingSpot`, with destructible tiles counted as cleared when `through`.
pub fn standingSpotThrough(rom: []const u8, b: []const u8, t: Tileset, py: u16, px: u16, through: bool) ?Spot {
    var g = grid(rom, b, t) orelse return null;
    g.through = through;
    return nearest(g, py, px, 5, false, 0) orelse nearest(g, py, px, ball_rows, true, 0);
}

/// `standingSpot`, but at least `away` pixels to one side of `(py, px)`:
/// beside an item orb, which is shot open and would hide her if she stood in
/// it, or clear of a Metroid, which would be on her the frame she arrived
/// (1.0 Step 5b). The nearest spot of any kind when no spot is that far.
pub fn standingSpotBeside(rom: []const u8, b: []const u8, t: Tileset, py: u16, px: u16, away: u16) ?Spot {
    return standingSpotIn(rom, b, t, py, px, away, null);
}

/// A cell's place in its bank and the room's reach: a spot must be one a
/// player gets to (1.0 Step 18f).
pub const Within = struct { reach: *const Reach, cell: map.Cell };

/// `standingSpotBeside`, held inside `within` when it is given: the warp's
/// spot (1.0 Step 18f). Metroid 11's was a pocket sealed in the rock.
pub fn standingSpotIn(rom: []const u8, b: []const u8, t: Tileset, py: u16, px: u16, away: u16, within: ?Within) ?Spot {
    var g = grid(rom, b, t) orelse return null;
    g.within = within;
    return nearest(g, py, px, 5, false, away) orelse nearest(g, py, px, ball_rows, true, away) orelse
        nearest(g, py, px, 5, false, 0) orelse nearest(g, py, px, ball_rows, true, 0);
}

/// How far to one side of an item orb, and of a Metroid, the warp puts her.
pub const beside_item: u16 = 24;
pub const beside_metroid: u16 = 48;

/// Tile rows the ball fills above its floor: it is two tiles high.
pub const ball_rows: usize = 2;

/// The spot nearest `(py, px)` with `rows` tile rows clear above a floor in
/// both probe columns. The feet on tile row `fr` put y at 8*fr - $1C; x at
/// 8*k puts the probes on columns k and k+1.
fn nearest(g: Grid, py: u16, px: u16, rows: usize, morph: bool, away: u16) ?Spot {
    var best: ?Spot = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (rows..32) |fr| {
        for (0..31) |k| {
            if (!(g.floor(fr, k) or g.floor(fr, k + 1))) continue;
            var ok = true;
            for (fr - rows..fr) |r| {
                if (!g.clear(r, k) or !g.clear(r, k + 1)) ok = false;
            }
            if (!ok) continue;
            const y: i32 = @as(i32, @intCast(fr * 8)) - feet;
            if (y < 0) continue;
            const x: i32 = @intCast(k * 8);
            if (g.within) |in| if (!in.reach.holds((@as(u16, in.cell.y) << 8) | @as(u16, @intCast(y)), (@as(u16, in.cell.x) << 8) | @as(u16, @intCast(x)))) continue;
            const dy = (y + 10) - @as(i32, py);
            const dx = (x + 8) - @as(i32, px);
            if (@abs(dx) < away) continue;
            const d: u32 = @intCast(dy * dy + dx * dx);
            if (d < best_d) {
                best_d = d;
                best = .{ .y = @intCast(y), .x = @intCast(x), .morph = morph };
            }
        }
    }
    return best;
}

/// Where the crawl stands Samus to try a door: one or two tiles from the
/// edge `dir` leaves by (James, 2026-09-27), destructible blocks counted as
/// cleared. Across a side edge, standing with her leading probe one or two
/// tiles short of it, on every row that allows it. Down, in the air over each
/// opening in the floor edge, to fall through. Up, standing under each
/// opening in the ceiling edge, as high as she can stand, to jump through.
/// At most `out.len`, spread along the edge.
pub fn spotsNear(rom: []const u8, b: []const u8, t: Tileset, dir: roster.Dir, out: []Spot) []Spot {
    var g = grid(rom, b, t) orelse return out[0..0];
    g.through = true;
    var all: [64]Spot = undefined;
    var n: usize = 0;
    const standAt = struct {
        fn f(gg: Grid, fr: usize, k: usize) bool {
            if (!(gg.floor(fr, k) or gg.floor(fr, k + 1))) return false;
            for (fr - 5..fr) |r| if (!gg.clear(r, k) or !gg.clear(r, k + 1)) return false;
            return fr * 8 >= feet;
        }
    }.f;
    switch (dir) {
        .right, .left => {
            const ks = if (dir == .right) [2]usize{ 29, 28 } else [2]usize{ 1, 2 };
            for (5..32) |fr| for (ks) |k| {
                if (!standAt(g, fr, k) or n == all.len) continue;
                all[n] = .{ .y = @intCast(fr * 8 - feet), .x = @intCast(k * 8) };
                n += 1;
                break;
            };
        },
        .down => for (0..31) |k| {
            var ok = true;
            for (24..32) |r| if (!g.clear(r, k) or !g.clear(r, k + 1)) {
                ok = false;
            };
            if (!ok or n == all.len) continue;
            all[n] = .{ .y = @intCast(29 * 8 - feet), .x = @intCast(k * 8) };
            n += 1;
        },
        .up => for (0..31) |k| {
            if (!g.clear(0, k) or !g.clear(0, k + 1) or !g.clear(1, k) or !g.clear(1, k + 1)) continue;
            for (5..32) |fr| if (standAt(g, fr, k)) {
                if (n < all.len) {
                    all[n] = .{ .y = @intCast(fr * 8 - feet), .x = @intCast(k * 8) };
                    n += 1;
                }
                break;
            };
        },
    }
    if (n <= out.len) {
        @memcpy(out[0..n], all[0..n]);
        return out[0..n];
    }
    for (out, 0..) |*o, i| o.* = all[i * (n - 1) / (out.len - 1)];
    return out;
}

// ---- Whether she can walk out (1.0 Step 18f) ---------------------------------

/// Tiles $00-$03 are respawning blocks whatever the collision table says: a
/// bomb or a beam clears them (01:$2433, 01:$16FC: `cp $04`, then
/// `destroyRespawningBlock`). Found by the recording passing through them into
/// the ruins' item chambers (`$D:$4D`, 1.0 Step 18f).
pub const respawning_tiles: u8 = 0x04;

/// The block the baby Metroid eats (`baby_checkBlocks`, 02:$7D2A, `cp $64`),
/// after the Queen: in the way until then, and the post-Queen route's way out after.
pub const baby_tile: u8 = 0x64;

/// Tiles along a bank's side: sixteen cells of 32. Positions wrap as the cell
/// grid does (`roster.Dir.step`).
const bank_tiles: usize = map.grid_w * 32;

/// Where in a room a ball can get to from a door out of it, with every item:
/// the Space Jump and the Spider Ball take it anywhere the rock leaves two
/// tiles clear, and a destructible block counts as cleared (a tunnel behind
/// one is a player's way in, James 2026-10-01). Hurting tiles are crossed.
/// A spot outside it is one no player stands in.
pub const Reach = struct {
    /// Per bank tile: in the room and not in the way.
    open: std.DynamicBitSetUnmanaged,
    /// Per ball position (its top-left tile): reached from a door.
    seen: std.DynamicBitSetUnmanaged,

    pub fn deinit(self: *Reach, allocator: std.mem.Allocator) void {
        self.open.deinit(allocator);
        self.seen.deinit(allocator);
    }

    /// Whether Samus at bank position `(y, x)` is in it: the ball she would
    /// be, two tile rows over her feet, between her probe columns. Past a
    /// door's trigger, on her way across the edge, she is held to the edge.
    pub fn holds(self: Reach, y: u16, x: u16) bool {
        const r = ((@as(usize, y & 0x0FFF) + feet) / 8 + bank_tiles - ball_rows) % bank_tiles;
        const c = ((@as(usize, x & 0x0FFF) + probe_left) / 8) % bank_tiles;
        if (self.seen.isSet(tileIndex(r, c))) return true;
        return self.seen.isSet(tileIndex(r - r % 32 + @min(r % 32, 30), c - c % 32 + @min(c % 32, 30)));
    }

    /// `holds`, for a position read off a moving Samus rather than a spot:
    /// a ball position that overlaps her, a tile either way, will do. Her
    /// pixel offset in a jump through a two-tile gap straddles three rows.
    pub fn near(self: Reach, y: u16, x: u16) bool {
        if (self.holds(y, x)) return true;
        for ([_]u16{ 0, 8, 0x1000 - 8 }) |dy| for ([_]u16{ 0, 8, 0x1000 - 8 }) |dx| {
            if (self.holds((y +% dy) & 0x0FFF, (x +% dx) & 0x0FFF)) return true;
        };
        return false;
    }

    fn fits(self: Reach, r: usize, c: usize) bool {
        for (0..2) |dr| for (0..2) |dc| if (!self.open.isSet(tileIndex(r + dr, c + dc))) return false;
        return true;
    }
};

fn tileIndex(r: usize, c: usize) usize {
    return (r % bank_tiles) * bank_tiles + (c % bank_tiles);
}

/// Whether the ball, its top-left tile at `(r, k)` in the cell a door leaves,
/// comes out of it somewhere it fits: a door is no way out into rock (James's
/// playtest, 2026-10-01: `$B:$44`'s floor is lava over a blocked edge, and
/// `$B:$54`'s top below it is rock). Crossing into the cell beside, she
/// arrives at its near edge. Checked only where the far side is known: a
/// door script into the cell beside that loads no table, so the cell is drawn
/// under `t`. A `WARP`, or a door that loads tables, may draw it with ones
/// this does not know (with those checked, the recording's positions out of
/// reach went from 39 to 292), and a crossing with no script (index 0) is not
/// the plain step it looks: with it checked, Metroid 01's room, which the
/// recording walks out of, had no way out.
fn lands(rom: []const u8, w: roster.World, e: roster.Edge, t: Tileset, r: usize, k: usize) bool {
    const to = e.dest.to;
    const beside = to.bank == e.from.bank and to.cell == e.dir.step(e.from.cell).?;
    if (e.index == 0 or !beside or e.dest.tiletable != null or e.dest.collision != null) return true;
    const b = body(rom, w, to) orelse return false;
    var g = grid(rom, b, t) orelse return true;
    g.through = true;
    const ar: usize, const ak: usize = switch (e.dir) {
        .right => .{ r, @as(usize, 0) },
        .left => .{ r, @as(usize, 30) },
        .up => .{ @as(usize, 30), k },
        .down => .{ @as(usize, 0), k },
    };
    for (0..2) |dr| for (0..2) |dk| {
        if (g.isSolid(ar + dr, ak + dk) and g.tile(ar + dr, ak + dk) >= respawning_tiles) return false;
    };
    return true;
}

/// The ball's reach in `room` of `bank`, drawn under `t`, from every door the
/// room has out (`w.edges`): the ball where the door's trigger fires, with the
/// camera on that edge's clamp (`HandleCamera`). Right, her x at $F1 or more,
/// the ball on the cell's last two columns; left, past the cell's first; up,
/// her y under 1, the ball on rows 1-2; down, falling with her y at $D6 or
/// more, the ball's top on row 28 or below. So a door down can fire over a
/// floor, and a warp in through it puts her where she was, low in the cell.
/// Only where she comes out of the door with room to (`lands`).
pub fn reach(allocator: std.mem.Allocator, rom: []const u8, w: roster.World, bank: u8, room: u16, t: Tileset) !Reach {
    return reachWith(allocator, rom, w, bank, room, t, false);
}

/// `reach`, with the baby's blocks eaten when `baby` (the count at zero).
pub fn reachWith(allocator: std.mem.Allocator, rom: []const u8, w: roster.World, bank: u8, room: u16, t: Tileset, baby: bool) !Reach {
    var out: Reach = .{
        .open = try .initEmpty(allocator, bank_tiles * bank_tiles),
        .seen = try .initEmpty(allocator, bank_tiles * bank_tiles),
    };
    errdefer out.deinit(allocator);
    for (0..map.cells) |ci| {
        const p: roster.Place = .{ .bank = bank, .cell = @intCast(ci) };
        if (w.roomOf(p) != room) continue;
        const b = body(rom, w, p) orelse continue;
        var g = grid(rom, b, t) orelse continue;
        g.through = true;
        const c = w.cellOf(p);
        for (0..32) |r| for (0..32) |k| {
            if (!g.isSolid(r, k) or g.tile(r, k) < respawning_tiles or (baby and g.tile(r, k) == baby_tile)) out.open.set(tileIndex(@as(usize, c.y) * 32 + r, @as(usize, c.x) * 32 + k));
        };
    }

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    for (w.edges) |e| {
        if (e.from.bank != bank or w.roomOf(e.from) != room) continue;
        const c = w.cellOf(e.from);
        const r0 = @as(usize, c.y) * 32;
        const c0 = @as(usize, c.x) * 32;
        for (0..31) |i| for (0..3) |j| {
            const r, const k = switch (e.dir) {
                .right => if (j == 0) .{ r0 + i, c0 + 30 } else continue,
                .left => if (j == 0) .{ r0 + i, c0 } else continue,
                .up => if (j < 2) .{ r0 + j, c0 + i } else continue,
                .down => .{ r0 + 28 + j, c0 + i },
            };
            const at = tileIndex(r, k);
            if (out.seen.isSet(at) or !out.fits(r, k)) continue;
            if (!lands(rom, w, e, t, r - r0, k - c0)) continue;
            out.seen.set(at);
            try queue.append(allocator, @intCast(at));
        };
    }
    var head_i: usize = 0;
    while (head_i < queue.items.len) : (head_i += 1) {
        const at = queue.items[head_i];
        const r: usize = at / bank_tiles;
        const k: usize = at % bank_tiles;
        const next = [_][2]usize{ .{ r + 1, k }, .{ r + bank_tiles - 1, k }, .{ r, k + 1 }, .{ r, k + bank_tiles - 1 } };
        for (next) |n| {
            const ni = tileIndex(n[0], n[1]);
            if (out.seen.isSet(ni) or !out.fits(n[0], n[1])) continue;
            out.seen.set(ni);
            try queue.append(allocator, @intCast(ni));
        }
    }
    return out;
}

/// The camera for Samus at `(y, x)` in `cell`, held inside the clamps of
/// the edges the cell blocks.
pub fn cameraFor(cell: map.Cell, y: u16, x: u16) struct { u16, u16 } {
    const base_y: u16 = @as(u16, cell.y) << 8;
    const base_x: u16 = @as(u16, cell.x) << 8;
    var cy = y + cam_from_samus_y;
    var cx = x + cam_from_samus_x;
    if (cell.scroll.block_down and cy > base_y + clamp_down) cy = base_y + clamp_down;
    if (cell.scroll.block_up and cy < base_y + clamp_up) cy = base_y + clamp_up;
    if (cell.scroll.block_right and cx > base_x + clamp_right) cx = base_x + clamp_right;
    if (cell.scroll.block_left and cx < base_x + clamp_left) cx = base_x + clamp_left;
    return .{ cy & 0x0FFF, cx & 0x0FFF };
}

// ---- Building the entries ---------------------------------------------------

/// A destination the warp cannot serve, and why. Carried to James rather than
/// dropped (C8 wants every destination on the list).
pub const Finding = struct { dest: roster.Destination, why: []const u8, tileset: ?Tileset = null, basis: ?Basis = null };

pub const Built = struct {
    entries: []Entry,
    findings: []Finding,
    /// Rooms the door graph settles, of those the entries are in.
    settled: usize,

    pub fn deinit(self: *Built, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.findings);
    }
};

/// The pixel within the destination's cell that Samus is put nearest.
fn pointOf(rom: []const u8, w: roster.World, d: roster.Destination, t: Tileset, xs: []const Crossing) struct { u16, u16 } {
    switch (d.kind) {
        // On the pad (1.0 Step 18e): the feet on its top, the upper metatile's
        // bottom tile row, as `nearest` measures a spot (`y + 10`). Its
        // middle was nearer a floor beside it than the pad itself at
        // `$E:$54`, where she stood with no contact.
        .station => if (body(rom, w, d.at)) |b| if (roster.stationAt(rom, b, t.tiletable)) |m| {
            return .{ (@as(u16, m.row) * 2 + 1) * 8 - feet + 10, @as(u16, m.col) * 16 + 8 };
        },
        .item, .metroid => if (d.record orelse d.metroid) |rec| return .{ rec.y, rec.x },
        .metroid_before, .queen_before => {
            // The door out: the middle of the edge the crossing leaves by.
            for (xs) |x| {
                if (x.from.bank != d.at.bank or x.from.cell != d.at.cell) continue;
                if (d.door) |di| if (x.run.scripts[0] != di) continue;
                return switch (x.dir) {
                    .right => .{ 128, 240 },
                    .left => .{ 128, 16 },
                    .up => .{ 16, 128 },
                    .down => .{ 240, 128 },
                };
            }
        },
        else => {},
    }
    return .{ 128, 128 };
}

/// Whether the entering side of a crossing has an opening under `t`: the
/// leaving side is another room's, drawn with a tileset this does not know.
fn entering(rom: []const u8, w: roster.World, to: roster.Place, dir: roster.Dir, t: Tileset) bool {
    const b = body(rom, w, to) orelse return false;
    const mts = screens.metatileTable(rom, t.tiletable) orelse return false;
    for (0..map.grid_w) |i| if (open(mts, edgeAt(b, dir, false, i), t.solidity[0])) return true;
    return false;
}

/// The door into `room` the warp runs last, and the loader before it: a
/// crossing from another room, run at the new game's count after a script
/// that loads the tileset of the room it leaves. That is how a player arrives
/// -- the door changes what it names and keeps what it does not -- and a door
/// that tests the count, as every lava room's does, is the live count's to
/// take on both machines.
///
/// Best is a chain that leaves the table `want` names (what the door graph
/// or `screens.assign` says the room is drawn with), then one with an opening
/// under what it leaves, then one whose door loads the enemy page, then bank
/// and cell order.
const Choice = struct { chain: [max_chain]u16, n: u8, state: State };

fn chooseChain(
    rom: []const u8,
    w: roster.World,
    decoded: door.Decoded,
    ptrs: []const u8,
    rows: []const u8,
    xs: []const Crossing,
    room: u16,
    s0: State,
    want: u4,
    tilesetOf: anytype,
) ?Choice {
    var best: ?Choice = null;
    var best_score: u8 = 0;
    for (xs) |x| {
        if (x.run.queen or x.run.n == 0) continue;
        if (x.run.to.bank < map.first_bank or x.run.to.bank > map.last_bank) continue;
        if (!w.cellOf(x.run.to).inUse()) continue;
        if (w.roomOf(x.run.to) != room or w.roomOf(x.from) == room) continue;
        const index = x.run.scripts[0];
        _, const wr = runScript(decoded, ptrs, rows, s0, index, start_count);
        var c: Choice = .{ .chain = .{ index, 0 }, .n = 1, .state = undefined };
        if (wr & w_tileset != w_tileset) {
            const f = tilesetOf.of(x.from) orelse continue;
            const l = loaderFor(decoded, ptrs, rows, s0, f) orelse continue;
            c = .{ .chain = .{ l, index }, .n = 2, .state = undefined };
        }
        c.state = runChain(decoded, ptrs, rows, s0, c.chain[0..c.n]);
        var score: u8 = 1;
        if (c.state.tiletable == want) score += 8;
        if (entering(rom, w, x.run.to, x.dir, Tileset.of(c.state))) score += 4;
        if (wr & w_spr != 0) score += 2;
        if (score > best_score) {
            best_score = score;
            best = c;
        }
    }
    return best;
}

/// The tileset `screens.assign` gives a cell, and the door it was seeded
/// from, as that door loads it at the new game's count.
fn assigned(asg: screens.Assignment, decoded: door.Decoded, ptrs: []const u8, rows: []const u8, s0: State, p: roster.Place) ?struct { Tileset, u16 } {
    const c = asg.find(p.bank, @truncate(p.cell & 0x0F), @truncate(p.cell >> 4)) orelse return null;
    const ch = c.choice orelse return null;
    const s, _ = runScript(decoded, ptrs, rows, s0, ch.door_index, start_count);
    var t = Tileset.of(s);
    t.tiletable = ch.tiletable;
    return .{ t, ch.door_index };
}

/// The in-use cell a blank-cell destination is drawn beside: the one
/// `roomAt` took its room from.
fn drawnCell(w: roster.World, p: roster.Place) roster.Place {
    if (w.cellOf(p).inUse()) return p;
    for ([_]roster.Dir{ .right, .left, .up, .down }) |d| {
        const n: roster.Place = .{ .bank = p.bank, .cell = d.step(p.cell).? };
        if (w.cellOf(n).inUse()) return n;
    }
    return p;
}

/// The best walked door into `room` whose chain reproduces what the Game Boy
/// loaded: truth first, then at the new game's count, then one that loads an
/// enemy page, then the crawl's order (breadth first from the new game).
///
/// `pad`: a station's screen body (1.0 Step 18e). Only a door whose tileset
/// draws the station there is taken, when there is one: `$A:$99`'s room is
/// walked in through lava from `$A:$79`, which draws no pad, and through
/// `$17F` from `$F:$FC` under caveFirst, which does and is how the recording
/// comes in to save at count $01.
fn walkedChain(walked: []const WalkedDoor, rom: []const u8, room: u16, decoded: door.Decoded, ptrs: []const u8, rows: []const u8, s0: State, pad: ?[]const u8) ?struct { [max_chain]u16, u8, Basis, Tileset, u8 } {
    if (pad) |b| if (walkedChainAt(walked, rom, room, decoded, ptrs, rows, s0, 1, b)) |x| return x;
    return walkedChainAt(walked, rom, room, decoded, ptrs, rows, s0, 1, null);
}

/// `walkedChain`, following at most `depth` crossings that run no script back
/// to the room before.
fn walkedChainAt(walked: []const WalkedDoor, rom: []const u8, room: u16, decoded: door.Decoded, ptrs: []const u8, rows: []const u8, s0: State, depth: u8, pad: ?[]const u8) ?struct { [max_chain]u16, u8, Basis, Tileset, u8 } {
    var best: ?struct { [max_chain]u16, u8, Basis, Tileset, u8 } = null;
    var best_score: u8 = 0;
    for (walked) |wd| {
        if (wd.to_room != room or wd.from_room == room) continue;
        const want = tilesetOfBlock(rom, wd.to_block) orelse continue;
        var chain: [max_chain]u16 = .{ wd.door, 0 };
        var n: u8 = 1;
        const wr: Writes = if (wd.door == 0) 0 else runScript(decoded, ptrs, rows, s0, wd.door, wd.count)[1];
        if (wd.door == 0) {
            // 1.0 Step 14: a crossing that runs no script keeps the room
            // before's state. So the chain is a loader of that state entering
            // the same map bank, or else the room before's own chain when it
            // leaves that state; the warp puts her in this room either way.
            // Only from truth: a seeded crossing has nothing to add.
            if (!wd.to_truth) continue;
            if (loaderMatching(decoded, ptrs, rows, s0, want, false, @intCast(wd.to.bank)) orelse
                loaderMatching(decoded, ptrs, rows, s0, want, true, @intCast(wd.to.bank))) |l|
            {
                chain[0] = l;
            } else {
                if (depth == 0) continue;
                const x = walkedChainAt(walked, rom, wd.from_room, decoded, ptrs, rows, s0, depth - 1, null) orelse continue;
                if (!x[3].eql(want)) continue;
                chain = x[0];
                n = x[1];
            }
        } else if (wr & w_tileset != w_tileset) {
            const from = tilesetOfBlock(rom, wd.from_block) orelse continue;
            chain = .{ loaderFor(decoded, ptrs, rows, s0, from) orelse continue, wd.door };
            n = 2;
        }
        // The chain has to leave what the engine left, at the count walked.
        var s = s0;
        for (chain[0..n]) |ci| s, _ = runScript(decoded, ptrs, rows, s, ci, wd.count);
        if (!Tileset.of(s).eql(want)) continue;
        if (pad) |b| if (roster.stationAt(rom, b, want.tiletable) == null) continue;
        var score: u8 = 1;
        if (wd.to_truth) score += 8;
        if (wd.count == start_count) score += 4;
        if (wr & w_spr != 0) score += 2;
        if (score > best_score) {
            best_score = score;
            best = .{ chain, n, if (wd.to_truth) .walked else .seeded, want, wd.count };
        }
    }
    return best;
}

// ---- The recording's tables (1.0 Step 18f) ----------------------------------

/// Every visit `gbtrace -- reference/metroid2-100p-recording set worlds`
/// grades, with the metatile table Mesen's Game Boy showed. `set worlds`
/// fails when the recording stops saying them.
pub const recorded_tables = @embedFile("recorded_tables.txt");

pub const Recorded = packed struct { bank: u8, cell: u8, count: u8, table: u8 };

pub fn parseRecorded(allocator: std.mem.Allocator, text: []const u8) ![]Recorded {
    var out: std.ArrayList(Recorded) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        var r: Recorded = undefined;
        inline for (.{ "bank", "cell", "count", "table" }) |name| {
            @field(r, name) = try std.fmt.parseInt(u8, f.next() orelse return error.BadRecorded, 16);
        }
        if (f.next() != null or r.table >= screens.tiletable_order.len) return error.BadRecorded;
        try out.append(allocator, r);
    }
    return out.toOwnedSlice(allocator);
}

/// The recording's first visit to `cell`, else to another cell of its room:
/// the highest count, the first time a player stands there.
fn recordedFor(recorded: []const Recorded, w: roster.World, cell: roster.Place, room: u16) ?Recorded {
    var best: ?Recorded = null;
    for ([_]bool{ true, false }) |own| {
        for (recorded) |r| {
            if (r.bank != cell.bank) continue;
            if (own and r.cell != cell.cell) continue;
            if (!own and w.roomOf(.{ .bank = r.bank, .cell = r.cell }) != room) continue;
            if (best == null or r.count > best.?.count) best = r;
        }
        if (best != null) return best;
    }
    return null;
}

/// What an entry's chain leaves at a count, for a reader outside the build:
/// the warp runs it at the live count (1.0 Step 18f).
pub const Runner = struct {
    decoded: door.Decoded,
    ptrs: []const u8,
    rows: []const u8,
    s0: State,

    pub fn init(allocator: std.mem.Allocator, rom: []const u8) !Runner {
        var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
        errdefer decoded.deinit(allocator);
        return .{ .decoded = decoded, .ptrs = door.pointers(rom) orelse return Error.NoDoorData, .rows = thresholds(rom), .s0 = try initialState(rom, decoded) };
    }

    pub fn deinit(self: *Runner, allocator: std.mem.Allocator) void {
        self.decoded.deinit(allocator);
    }

    pub fn tilesetAt(self: Runner, e: Entry, count: u8) Tileset {
        return Tileset.of(chainAt(self.decoded, self.ptrs, self.rows, self.s0, e.chain[0..e.n], count));
    }
};

fn chainAt(decoded: door.Decoded, ptrs: []const u8, rows: []const u8, s0: State, chain: []const u16, count: u8) State {
    var s = s0;
    for (chain) |i| s, _ = runScript(decoded, ptrs, rows, s, i, count);
    return s;
}

fn testsCount(decoded: door.Decoded, ptrs: []const u8, chain: []const u16) bool {
    for (chain) |i| for (screens.scriptOps(decoded, ptrs, i) orelse continue) |op| if (op == .if_met_less) return true;
    return false;
}

const Held = struct { chain: [max_chain]u16, n: u8, tileset: Tileset, count: u8 };

/// The chain into `room` that leaves the recording's table at the recording's
/// count. The warp runs it at the live count, as walking in would, so no
/// warp needs a count set first (James, 2026-10-01); the entry's tileset is
/// what it leaves at the new game's. The chain the entry has is kept when it
/// leaves the recording's table. Otherwise a door into the room, alone when
/// it loads the table, else after a loader of it.
///
/// **A lava room keeps its lava.** Its chain must leave a lava table at the
/// new game's count too, and best is one whose level moves between the two
/// counts, as the area's own lava doors' does (`$04A`: lavaCavesMid at $47,
/// lavaCavesEmpty from $46): the warp then draws the level the live count
/// gives. Any other room's best chain does not test the count, so it draws
/// the recording's table at any count. Then a loader that leaves a tileset
/// our Game Boy arrived somewhere with; then one entering the room's bank;
/// then a door the Game Boy walked.
fn heldToRecording(
    rom: []const u8,
    w: roster.World,
    decoded: door.Decoded,
    ptrs: []const u8,
    rows: []const u8,
    xs: []const Crossing,
    walked: []const WalkedDoor,
    s0: State,
    room: u16,
    bank: u8,
    rec: Recorded,
    have: []const u16,
) ?Held {
    const finish = struct {
        fn f(dd: door.Decoded, pp: []const u8, rr: []const u8, ss: State, chain: [max_chain]u16, n: u8, r: Recorded) Held {
            _ = r;
            return .{ .chain = chain, .n = n, .tileset = Tileset.of(chainAt(dd, pp, rr, ss, chain[0..n], start_count)), .count = start_count };
        }
    }.f;
    const lava = isLavaTable(@intCast(rec.table));
    const keeps = !lava or isLavaTable(chainAt(decoded, ptrs, rows, s0, have, start_count).tiletable);
    if (keeps and chainAt(decoded, ptrs, rows, s0, have, rec.count).tiletable == rec.table) {
        var c: [max_chain]u16 = .{ 0, 0 };
        @memcpy(c[0..have.len], have);
        return finish(decoded, ptrs, rows, s0, c, @intCast(have.len), rec);
    }

    var doors: [64]struct { u16, bool } = undefined;
    var nd: usize = 0;
    for (walked) |wd| {
        if (wd.to_room != room or wd.from_room == room or wd.door == 0 or wd.to.bank != bank) continue;
        for (doors[0..nd]) |x| {
            if (x[0] == wd.door) break;
        } else if (nd < doors.len) {
            doors[nd] = .{ wd.door, true };
            nd += 1;
        }
    }
    for (xs) |x| {
        if (x.run.queen or x.run.n == 0 or x.run.to.bank != bank) continue;
        if (w.roomOf(x.run.to) != room or w.roomOf(x.from) == room) continue;
        for (doors[0..nd]) |y| {
            if (y[0] == x.run.scripts[0]) break;
        } else if (nd < doors.len) {
            doors[nd] = .{ x.run.scripts[0], false };
            nd += 1;
        }
    }

    var best: ?[max_chain]u16 = null;
    var best_n: u8 = 0;
    var best_score: u8 = 0;
    for (doors[0..nd]) |dw| {
        const di, const was_walked = dw;
        const alone, const wr = runScript(decoded, ptrs, rows, s0, di, rec.count);
        var opts: [door.pointer_count]u16 = undefined;
        var no: usize = 0;
        if (wr & w_tileset == w_tileset) {
            if (alone.tiletable != rec.table) continue;
            opts[0] = 0;
            no = 1;
        } else for (1..door.pointer_count) |i| {
            const ops = screens.scriptOps(decoded, ptrs, i) orelse continue;
            var queen = false;
            var warps = false;
            for (ops) |op| switch (op) {
                .warp => warps = true,
                .enter_queen, .exit_queen, .escape_queen => queen = true,
                else => {},
            };
            if (queen or !warps) continue;
            const s, const lw = runScript(decoded, ptrs, rows, s0, @intCast(i), rec.count);
            if (lw & w_tileset != w_tileset or s.tiletable != rec.table) continue;
            opts[no] = @intCast(i);
            no += 1;
        }
        for (opts[0..no]) |l| {
            const chain: [max_chain]u16 = if (l == 0) .{ di, 0 } else .{ l, di };
            const n: u8 = if (l == 0) 1 else 2;
            const s = chainAt(decoded, ptrs, rows, s0, chain[0..n], rec.count);
            if (s.tiletable != rec.table) continue;
            const at_start = chainAt(decoded, ptrs, rows, s0, chain[0..n], start_count).tiletable;
            if (lava and !isLavaTable(at_start)) continue;
            var score: u8 = 1;
            if (if (lava) at_start != rec.table else !testsCount(decoded, ptrs, chain[0..n])) score += 16;
            if (l == 0) score += 8 else for (walked) |wd| {
                const t = tilesetOfBlock(rom, wd.to_block) orelse continue;
                if (t.eql(Tileset.of(s))) {
                    score += 8;
                    break;
                }
            }
            if (l == 0 or warpBank(decoded, ptrs, l, rec.count) == @as(u4, @intCast(bank & 0xF))) score += 4;
            if (was_walked) score += 2;
            if (score > best_score) {
                best_score = score;
                best = chain;
                best_n = n;
            }
        }
    }
    const chain = best orelse return null;
    return finish(decoded, ptrs, rows, s0, chain, best_n, rec);
}

pub fn build(allocator: std.mem.Allocator, rom: []const u8, walked: []const WalkedDoor) !Built {
    var w = try roster.world(allocator, rom);
    defer w.deinit(allocator);
    var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    const rows = thresholds(rom);
    const xs = try crossings(allocator, rom, w, decoded);
    defer allocator.free(xs);
    var st = try settle(allocator, rom, w, decoded, xs);
    defer st.deinit(allocator);
    var asg = try screens.assign(allocator, rom);
    defer asg.deinit(allocator);
    const dests = try roster.destinations(allocator, rom, w);
    defer allocator.free(dests);
    const s0 = try initialState(rom, decoded);
    const init = save.initial(rom) orelse return Error.NoInitialSave;
    const recorded = try parseRecorded(allocator, recorded_tables);
    defer allocator.free(recorded);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var findings: std.ArrayList(Finding) = .empty;
    errdefer findings.deinit(allocator);
    var settled: usize = 0;

    for (dests) |d0| {
        // Where to try it. A room *before* a Metroid can be any room a door
        // the Game Boy walked leads into the Metroid's room from; the one Step 1
        // listed is tried first, and the others when it cannot be stood in.
        var cands: std.ArrayList(roster.Place) = .empty;
        defer cands.deinit(allocator);
        try cands.append(allocator, d0.at);
        if (d0.kind == .metroid_before) if (d0.metroid) |mr| {
            const target = roomAt(w, .{ .bank = mr.bank, .cell = mr.cell });
            for (walked) |wd| {
                if (wd.to_room != target or wd.from_room == target) continue;
                for (cands.items) |c| {
                    if (c.bank == wd.from.bank and c.cell == wd.from.cell) break;
                } else try cands.append(allocator, wd.from);
            }
        };
        cand: for (cands.items, 0..) |at, ci| {
            const last = ci + 1 == cands.items.len;
            var d = d0;
            d.at = at;
            // Her room (1.0 Step 6): the one door that runs `ENTER_QUEEN`, which
            // loads the whole tileset and places Samus and the camera itself.
            if (d.kind == .queen) {
                const q = queenDoor(decoded, ptrs) orelse {
                    if (last) try findings.append(allocator, .{ .dest = d, .why = "no door script runs ENTER_QUEEN" });
                    continue :cand;
                };
                try entries.append(allocator, .{
                    .dest = d,
                    .chain = .{ q.index, 0 },
                    .n = 1,
                    .basis = .walked,
                    .disagrees = false,
                    .tileset = Tileset.of(runChain(decoded, ptrs, rows, s0, &.{q.index})),
                    .count = start_count,
                    .samus_y = q.op.samus_y,
                    .samus_x = q.op.samus_x,
                    .cam_y = q.op.scroll_y,
                    .cam_x = q.op.scroll_x,
                });
                break :cand;
            }
            const room = roomAt(w, d.at);
            if (room == roster.World.none) {
                if (last) try findings.append(allocator, .{ .dest = d, .why = "in no room of the door graph" });
                continue :cand;
            }
            const cell = drawnCell(w, d.at);
            const graph = st.one(room);
            if (graph != null) settled += 1;
            const by_asg = assigned(asg, decoded, ptrs, rows, s0, cell);
            const want: Tileset = graph orelse (if (by_asg) |x| x[0] else {
                if (last) try findings.append(allocator, .{ .dest = d, .why = "neither the door graph nor screens.assign gives a tileset" });
                continue :cand;
            });

            // The chain: a door the Game Boy walked into the room, else the
            // static reading's.
            var chain: [max_chain]u16 = undefined;
            var n: u8 = undefined;
            var basis: Basis = .inferred;
            var t: Tileset = undefined;
            var count: u8 = start_count;
            const pad = if (d.kind == .station) body(rom, w, d.at) else null;
            if (walkedChain(walked, rom, room, decoded, ptrs, rows, s0, pad)) |x| {
                chain, n, basis, t, count = x;
            } else {
                const Lookup = struct {
                    w: roster.World,
                    st: *const Settled,
                    asg: *const screens.Assignment,
                    decoded: door.Decoded,
                    ptrs: []const u8,
                    rows: []const u8,
                    s0: State,
                    fn of(self: @This(), p: roster.Place) ?Tileset {
                        if (self.st.one(roomAt(self.w, p))) |g| return g;
                        const x = assigned(self.asg.*, self.decoded, self.ptrs, self.rows, self.s0, drawnCell(self.w, p)) orelse return null;
                        return x[0];
                    }
                };
                const look: Lookup = .{ .w = w, .st = &st, .asg = &asg, .decoded = decoded, .ptrs = ptrs, .rows = rows, .s0 = s0 };
                if (chooseChain(rom, w, decoded, ptrs, rows, xs, room, s0, want.tiletable, look)) |c| {
                    chain = c.chain;
                    n = c.n;
                } else {
                    // No door in (the ship's room): a loader for the tileset wanted.
                    const l = loaderFor(decoded, ptrs, rows, s0, want) orelse (if (by_asg) |x| x[1] else {
                        if (last) try findings.append(allocator, .{ .dest = d, .why = "no door in, and no door script loads its tileset" });
                        continue :cand;
                    });
                    chain = .{ l, 0 };
                    n = 1;
                }
                t = Tileset.of(runChain(decoded, ptrs, rows, s0, chain[0..n]));
            }
            // 1.0 Step 18f: where the recording stood in the room, the table
            // it showed there. Metroid 11's room drew caveFirst where the
            // recording shows lavaCavesEmpty, and her spot in it was a pocket
            // sealed in that rock.
            if (d.kind != .ship) if (recordedFor(recorded, w, cell, room)) |rec| {
                if (heldToRecording(rom, w, decoded, ptrs, rows, xs, walked, s0, room, cell.bank, rec, chain[0..n])) |h| {
                    if (h.tileset.tiletable != t.tiletable or h.count != count) basis = .recorded;
                    chain, n, t, count = .{ h.chain, h.n, h.tileset, h.count };
                }
            };
            const disagrees = t.tiletable != want.tiletable;

            // Where she stands.
            const c = w.cellOf(cell);
            var sy: u16 = undefined;
            var sx: u16 = undefined;
            var cy: u16 = undefined;
            var cx: u16 = undefined;
            var morph = false;
            if (d.kind == .ship) {
                sy = init.samus_y;
                sx = init.samus_x;
                cy = init.cam_y;
                cx = init.cam_x;
            } else {
                const b = body(rom, w, cell) orelse {
                    if (last) try findings.append(allocator, .{ .dest = d, .why = "its cell has no screen body" });
                    continue :cand;
                };
                const py, const px = pointOf(rom, w, d, t, xs);
                var r = try reach(allocator, rom, w, cell.bank, w.roomOf(cell), t);
                defer r.deinit(allocator);
                const spot = standingSpotIn(rom, b, t, py, px, switch (d.kind) {
                    .item => beside_item,
                    .metroid => beside_metroid,
                    else => 0,
                }, .{ .reach = &r, .cell = c }) orelse {
                    if (last) try findings.append(allocator, .{ .dest = d, .why = "no spot in its cell a player reaches from a door", .tileset = t, .basis = basis });
                    continue :cand;
                };
                sy = (@as(u16, c.y) << 8) | spot.y;
                sx = (@as(u16, c.x) << 8) | spot.x;
                cy, cx = cameraFor(c, sy, sx);
                morph = spot.morph;
            }
            try entries.append(allocator, .{
                .dest = d,
                .chain = chain,
                .n = n,
                .basis = basis,
                .disagrees = disagrees,
                .tileset = t,
                .count = count,
                .samus_y = sy,
                .samus_x = sx,
                .cam_y = cy,
                .cam_x = cx,
                .morph = morph,
            });
            break :cand;
        }
    }
    return .{ .entries = try entries.toOwnedSlice(allocator), .findings = try findings.toOwnedSlice(allocator), .settled = settled };
}

// ---- Every door, for the `doors` rung (1.0 Step 18a) --------------------------

pub const DoorEntries = struct {
    /// One per door script, in door order.
    entries: []Entry,
    /// Pointers that land on no operation boundary.
    undecodable: usize,
    /// `ENTER_QUEEN`'s one, her room, which is the WARP page's own entry and
    /// the `queen` rung's. `ESCAPE_QUEEN` and `EXIT_QUEEN` run here since 1.0
    /// Step 20d.
    queen: usize,
    /// Never walked at the new game's count and no `WARP` of their own: a
    /// script with nowhere to put her. The unit test over the opcodes still
    /// covers them.
    nowhere: usize,
    /// Walked, but with no loader for the room before, or no chain that
    /// leaves what the engine left: findings.
    unchained: []u16,

    pub fn deinit(self: *DoorEntries, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.unchained);
    }
};

/// Every door script as a warp entry, for the `doors` rung (1.0 Step 18a).
///
/// A door the crawl walked at the new game's count is entered as a player
/// enters it: the chain is the loader of the room it leaves, then the door
/// (or the door alone when it loads a whole tileset), and it must leave what
/// the engine left. Truth first, then walked from truth. She stands nearest
/// the edge she came in by.
///
/// A door never walked there, but with a `WARP` of its own at that count, is
/// run alone into its `WARP` cell, with whatever the entry before it left:
/// both machines run the same sequence, so what it leaves is still graded,
/// but no stand is, since no walk says where she could be.
pub fn doorEntries(allocator: std.mem.Allocator, rom: []const u8, walked: []const WalkedDoor) !DoorEntries {
    var w = try roster.world(allocator, rom);
    defer w.deinit(allocator);
    var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    const rows = thresholds(rom);
    const s0 = try initialState(rom, decoded);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);
    var unchained: std.ArrayList(u16) = .empty;
    errdefer unchained.deinit(allocator);
    var out: DoorEntries = .{ .entries = &.{}, .undecodable = 0, .queen = 0, .nowhere = 0, .unchained = &.{} };

    for (1..door.pointer_count) |ii| {
        const i: u16 = @intCast(ii);
        const ops = screens.scriptOps(decoded, ptrs, i) orelse {
            out.undecodable += 1;
            continue;
        };
        // `ENTER_QUEEN` is her room's, which the `queen` rung grades. Door
        // $19E's `ESCAPE_QUEEN` and $19F's `EXIT_QUEEN` leave it into a map
        // bank, and run here as any door (1.0 Step 20d).
        const queen = for (ops) |op| switch (op) {
            .enter_queen => break true,
            else => {},
        } else false;
        if (queen) {
            out.queen += 1;
            continue;
        }
        _, const wr = runScript(decoded, ptrs, rows, s0, i, start_count);

        var best: ?Entry = null;
        var best_score: u8 = 0;
        var tried = false;
        for (walked) |wd| {
            if (wd.door != i or wd.count != start_count) continue;
            tried = true;
            const want = tilesetOfBlock(rom, wd.to_block) orelse continue;
            var chain: [max_chain]u16 = .{ i, 0 };
            var n: u8 = 1;
            if (wr & w_tileset != w_tileset) {
                const from = tilesetOfBlock(rom, wd.from_block) orelse continue;
                chain = .{ loaderFor(decoded, ptrs, rows, s0, from) orelse continue, i };
                n = 2;
            }
            const t = Tileset.of(runChain(decoded, ptrs, rows, s0, chain[0..n]));
            if (!t.eql(want)) continue;
            var score: u8 = 1;
            if (wd.to_truth) score += 8;
            if (wd.from_truth) score += 4;
            if (score <= best_score) continue;
            // In by the edge opposite the one she left by.
            const py: u16, const px: u16 = switch (wd.dir) {
                .right => .{ 128, 24 },
                .left => .{ 128, 232 },
                .down => .{ 24, 128 },
                .up => .{ 232, 128 },
            };
            const e = placed(rom, w, .{ .kind = .door, .at = wd.to, .door = i }, chain, n, if (wd.to_truth) .walked else .seeded, t, py, px) orelse continue;
            best_score = score;
            best = e;
        }
        if (best) |e| {
            try entries.append(allocator, e);
            continue;
        }
        if (tried) {
            try unchained.append(allocator, i);
            continue;
        }
        // Never walked at the new game's count: into its own `WARP`, if it has one.
        const p = warpCellOf(decoded, ptrs, i, start_count) orelse {
            out.nowhere += 1;
            continue;
        };
        const t = Tileset.of(runChain(decoded, ptrs, rows, s0, &.{i}));
        var e = placed(rom, w, .{ .kind = .door, .at = drawnCell(w, p), .door = i }, .{ i, 0 }, 1, .inferred, t, 128, 128) orelse {
            out.nowhere += 1;
            continue;
        };
        // What the entry before left decides the rest: no stand is graded.
        e.stand = false;
        try entries.append(allocator, e);
    }
    out.entries = try entries.toOwnedSlice(allocator);
    out.unchained = try unchained.toOwnedSlice(allocator);
    return out;
}

/// Where door `index`'s own `WARP` goes at `count`, following a branch the
/// count takes; null for a door that does not warp into a map bank.
fn warpCellOf(decoded: door.Decoded, ptrs: []const u8, index: u16, count: u8) ?roster.Place {
    var to: ?roster.Place = null;
    var at = index;
    var hops: usize = 0;
    outer: while (hops < 8) : (hops += 1) {
        for (screens.scriptOps(decoded, ptrs, at) orelse break) |op| switch (op) {
            .if_met_less => |x| if (x.met_count >= count) {
                at = x.transition;
                continue :outer;
            },
            .warp => |x| to = .{ .bank = x.bank, .cell = x.pos },
            else => {},
        };
        break;
    }
    const p = to orelse return null;
    if (p.bank < map.first_bank or p.bank > map.last_bank) return null;
    return p;
}

/// An entry for `d`, stood nearest `(py, px)` in its cell under `t`, or put in
/// the middle with no stand graded when the cell has no spot. Null when the
/// cell has no screen.
fn placed(rom: []const u8, w: roster.World, d: roster.Destination, chain: [max_chain]u16, n: u8, basis: Basis, t: Tileset, py: u16, px: u16) ?Entry {
    const c = w.cellOf(d.at);
    const b = body(rom, w, d.at) orelse return null;
    var e: Entry = .{
        .dest = d,
        .chain = chain,
        .n = n,
        .basis = basis,
        .disagrees = false,
        .tileset = t,
        .count = start_count,
        .samus_y = undefined,
        .samus_x = undefined,
        .cam_y = undefined,
        .cam_x = undefined,
    };
    var sy: u8 = 128;
    var sx: u8 = 128;
    if (standingSpot(rom, b, t, py, px)) |s| {
        sy = s.y;
        sx = s.x;
        e.morph = s.morph;
    } else e.stand = false;
    e.samus_y = (@as(u16, c.y) << 8) | sy;
    e.samus_x = (@as(u16, c.x) << 8) | sx;
    e.cam_y, e.cam_x = cameraFor(c, e.samus_y, e.samus_x);
    return e;
}

// ---- The counts a door tests (1.0 Step 18d) ----------------------------------

/// The `IF_MET_LESS` operands script `index` tests, its branches followed.
pub fn testsOf(decoded: door.Decoded, ptrs: []const u8, index: u16, out: *[16]u8) []u8 {
    var n: usize = 0;
    var todo: [16]u16 = undefined;
    var nt: usize = 1;
    todo[0] = index;
    var hops: usize = 0;
    while (nt > 0 and hops < 16) : (hops += 1) {
        nt -= 1;
        for (screens.scriptOps(decoded, ptrs, todo[nt]) orelse continue) |op| switch (op) {
            .if_met_less => |x| {
                if (std.mem.indexOfScalar(u8, out[0..n], x.met_count) == null and n < out.len) {
                    out[n] = x.met_count;
                    n += 1;
                }
                if (nt < todo.len) {
                    todo[nt] = x.transition;
                    nt += 1;
                }
            },
            else => {},
        };
    }
    return out[0..n];
}

/// One more Metroid, in the count's BCD.
pub fn bcdUp(c: u8) u8 {
    return if (c & 0x0F == 9) (c & 0xF0) + 0x10 else c + 1;
}

/// Where script `index` sends Samus at `count`: a `WARP`'s cell, or her room.
const Sent = union(enum) {
    none,
    cell: roster.Place,
    queen: @FieldType(door.Op, "enter_queen"),
};

fn sentBy(decoded: door.Decoded, ptrs: []const u8, index: u16, count: u8) Sent {
    var to: Sent = .none;
    var at = index;
    var hops: usize = 0;
    outer: while (hops < 8) : (hops += 1) {
        for (screens.scriptOps(decoded, ptrs, at) orelse break) |op| switch (op) {
            .if_met_less => |x| if (x.met_count >= count) {
                at = x.transition;
                continue :outer;
            },
            .warp => |x| to = .{ .cell = .{ .bank = x.bank, .cell = x.pos } },
            .enter_queen => |q| to = .{ .queen = q },
            else => {},
        };
        break;
    }
    return to;
}

/// The `doors` rung's entries again, at the counts their scripts test
/// (1.0 Step 18d): for every operand a door's chain tests, the count at it,
/// where the branch is taken, and the one above it, where it is not --
/// wherever the two leave another tileset or send her elsewhere. Every lava
/// door's levels are among them, and both sides of each threshold a door
/// entry's chain tests. Highest count first, so a run reaches each by killing
/// from the METROIDS page, and never by reviving.
///
/// Each is stood again under what its count loads; a side that sends her
/// where the walk did not is placed in its own `WARP` cell, or her room for
/// `ENTER_QUEEN`. No stand is graded: a kill arms the quake, which moves her.
pub fn countedEntries(allocator: std.mem.Allocator, rom: []const u8, doors: []const Entry) ![]Entry {
    var w = try roster.world(allocator, rom);
    defer w.deinit(allocator);
    var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    const rows = thresholds(rom);
    const s0 = try initialState(rom, decoded);

    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(allocator);
    for (doors) |d| {
        const chain = d.chain[0..d.n];
        var tb: [16]u8 = undefined;
        var counts: [32]u8 = undefined;
        var nc: usize = 0;
        for (chain) |si| for (testsOf(decoded, ptrs, si, &tb)) |x| {
            const hi = bcdUp(x);
            if (hi > start_count) continue;
            const S = struct {
                fn leaves(dc: door.Decoded, p: []const u8, r: []const u8, s: State, ch: []const u16, c: u8) struct { Tileset, Sent } {
                    var st = s;
                    for (ch) |i| st, _ = runScript(dc, p, r, st, i, c);
                    return .{ Tileset.of(st), sentBy(dc, p, ch[ch.len - 1], c) };
                }
            };
            if (std.meta.eql(S.leaves(decoded, ptrs, rows, s0, chain, x), S.leaves(decoded, ptrs, rows, s0, chain, hi))) continue;
            for ([_]u8{ hi, x }) |c| if (std.mem.indexOfScalar(u8, counts[0..nc], c) == null and nc < counts.len) {
                counts[nc] = c;
                nc += 1;
            };
        };
        for (counts[0..nc]) |c| {
            var st = s0;
            for (chain) |i| st, _ = runScript(decoded, ptrs, rows, st, i, c);
            const t = Tileset.of(st);
            // Stood again under what the count loads: a floor of one lava
            // level is not one at another.
            var e = placed(rom, w, d.dest, d.chain, d.n, d.basis, t, d.samus_y & 0xFF, d.samus_x & 0xFF) orelse continue;
            const sent = sentBy(decoded, ptrs, chain[chain.len - 1], c);
            if (!std.meta.eql(sent, sentBy(decoded, ptrs, chain[chain.len - 1], start_count))) switch (sent) {
                .none => continue,
                .cell => |p| {
                    if (p.bank < map.first_bank or p.bank > map.last_bank) continue;
                    e = placed(rom, w, .{ .kind = .door, .at = drawnCell(w, p), .door = d.dest.door }, d.chain, d.n, d.basis, t, 128, 128) orelse continue;
                },
                .queen => |q| {
                    e.dest = .{ .kind = .queen, .at = roster.queenCell(q) };
                    e.samus_y, e.samus_x, e.cam_y, e.cam_x = .{ q.samus_y, q.samus_x, q.scroll_y, q.scroll_x };
                },
            };
            e.tileset = t;
            e.count = c;
            e.stand = false;
            try out.append(allocator, e);
        }
    }
    const items = try out.toOwnedSlice(allocator);
    std.mem.sort(Entry, items, {}, struct {
        fn gt(_: void, x: Entry, y: Entry) bool {
            return x.count > y.count;
        }
    }.gt);
    return items;
}

// ---- The tileset each cell is drawn with (1.0 Step 18c) ----------------------

/// `screens.assign` with the crawl's arrivals laid over it.
///
/// **The static reading infers; the crawl measured.** Every room our Game Boy
/// walked into from the new game (`to_truth`, at the new game's count) was
/// arrived in with what the door left loaded, and a room is one scroll region,
/// which is what the crawl stands Samus in. So where every such arrival into a
/// room drew with the same graphics and metatile table, each of the room's
/// cells takes that, as `.walked`. A room arrived in two ways keeps the static
/// reading: which one the Game Boy shows depends on the door. So does a room
/// the crawl reached only from a seed, or only at another count.
///
/// Not `screens.assign` itself: the crawl is seeded from it (`Inference`), so
/// the static reading has to stand without the crawl.
///
/// **And the walk re-decides `assign`'s veto**, for the cells it did not
/// reach. `assign` throws the inheritance pass away in banks $9 and $A on a
/// proxy, `collapsedPairs`, because nothing could measure them. Against the
/// walked cells, the vetoed reading agrees on 151 of bank $9's 151 and the
/// pass on 136; in bank $A the vetoed reading on 5 of 58 and the pass on 14.
/// So per bank, whichever of the two agrees with more walked cells draws the
/// rest, the vetoed one on a tie.
pub fn assignWalked(allocator: std.mem.Allocator, rom: []const u8, walked: []const WalkedDoor) !screens.Assignment {
    var asg = try screens.assign(allocator, rom);
    errdefer asg.deinit(allocator);
    var unvetoed = try screens.assignWith(allocator, rom, .{ .veto = false });
    defer unvetoed.deinit(allocator);
    var w = try roster.world(allocator, rom);
    defer w.deinit(allocator);
    var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    const rows = thresholds(rom);
    const s0 = try initialState(rom, decoded);

    const arrivals = try walkedArrivals(allocator, rom, walked);
    defer allocator.free(arrivals);

    // What each walked cell was drawn with, and which reading agrees more.
    const drawn = try allocator.alloc(?Tileset, asg.cells.len);
    defer allocator.free(drawn);
    var votes: [map.bank_count][2]usize = @splat(.{ 0, 0 });
    for (asg.cells, unvetoed.cells, drawn) |c, u, *d| {
        d.* = null;
        const r = w.roomOf(.{ .bank = c.bank, .cell = @as(u8, c.y) * 16 + c.x });
        if (r == roster.World.none or r >= arrivals.len) continue;
        const a = arrivals[r] orelse continue;
        const t = a.tileset orelse continue;
        d.* = t;
        const bi = c.bank - map.first_bank;
        if (c.choice) |ch| votes[bi][0] += @intFromBool(drawsAs(ch, t));
        if (u.choice) |ch| votes[bi][1] += @intFromBool(drawsAs(ch, t));
    }
    var vetoed: [map.bank_count]bool = @splat(false);
    for (asg.cells, unvetoed.cells) |*c, u| {
        const bi = c.bank - map.first_bank;
        if (votes[bi][1] > votes[bi][0]) {
            if (c.choice) |old| asg.by_provenance[@intFromEnum(old.provenance)] -= 1;
            c.choice = u.choice;
            if (c.choice) |new| asg.by_provenance[@intFromEnum(new.provenance)] += 1;
        }
        const a = c.choice orelse continue;
        const b = u.choice orelse continue;
        if (!a.eql(b)) vetoed[bi] = true;
    }
    asg.vetoed_banks = std.mem.count(bool, &vetoed, &.{true});

    for (asg.cells, drawn) |*c, d| {
        const t = d orelse continue;
        const loader = drawingLoader(decoded, ptrs, rows, s0, t) orelse continue;
        if (c.choice) |old| asg.by_provenance[@intFromEnum(old.provenance)] -= 1;
        c.choice = .{
            .door_index = loader,
            .tiletable = t.tiletable,
            .bg_gfx = screens.entryNameAt(t.bg.bank, t.bg.addr),
            .provenance = .walked,
        };
        asg.by_provenance[@intFromEnum(screens.Provenance.walked)] += 1;
    }
    return asg;
}

/// A choice draws what `t` does: the same graphics and metatile table.
fn drawsAs(ch: screens.Choice, t: Tileset) bool {
    const name = screens.entryNameAt(t.bg.bank, t.bg.addr) orelse "";
    return ch.tiletable == t.tiletable and std.mem.eql(u8, ch.bg_gfx orelse "", name);
}

/// Per room, what the crawl's arrivals drew it with: the graphics and
/// metatile table of the first arrival in the crawl's order (breadth first
/// from the new game), or null where arrivals at two counts differ.
///
/// **An arrival's picture is the engine's** when it was walked out of a room
/// the crawl reached from the new game (`from_truth`), or when the door loads
/// both of them itself: then what the room before had does not reach the
/// picture, even out of a room the crawl seeded. A room whose picture the
/// count changes (the lava) is arrived in two ways and keeps the static
/// reading.
///
/// **At one count, the first arrival wins** (release Step 0). Until then any
/// two arrivals that differed left the room to the static reading, which was
/// tuned on a crawl cached before the crawler was committed (1058 doors). The
/// committed crawler walks 1185, reaches many rooms by several doors that
/// leave different pictures, and under that rule unsettled 137 cells: 388 of
/// the recording's visits missed against 312 pinned. The first arrival misses
/// 290, and loses 8 late-count visits the static reading happened to draw
/// right (`src/worlds_misses.txt`, accepted by James).
pub const Arrival = struct { tileset: ?Tileset, door: u16 };

pub fn walkedArrivals(allocator: std.mem.Allocator, rom: []const u8, walked: []const WalkedDoor) ![]?Arrival {
    var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    const rows = thresholds(rom);
    const s0 = try initialState(rom, decoded);
    var rooms: usize = 0;
    for (walked) |wd| if (wd.to_room != roster.World.none) {
        rooms = @max(rooms, @as(usize, wd.to_room) + 1);
    };
    const out = try allocator.alloc(?Arrival, rooms);
    @memset(out, null);
    // The count each room's first arrival was walked at.
    const first_count = try allocator.alloc(u8, rooms);
    defer allocator.free(first_count);
    for (walked) |wd| {
        if (wd.to_room == roster.World.none) continue;
        if (!wd.from_truth) {
            _, const wr = runScript(decoded, ptrs, rows, s0, wd.door, wd.count);
            if (wd.door == 0 or wr & (w_bg | w_tiletable) != w_bg | w_tiletable) continue;
        }
        const t = tilesetOfBlock(rom, wd.to_block) orelse continue;
        const slot = &out[wd.to_room];
        if (slot.*) |*a| {
            const had = a.tileset orelse continue;
            if (wd.count == first_count[wd.to_room]) continue;
            if (!had.bg.eql(t.bg) or had.tiletable != t.tiletable) a.tileset = null;
        } else {
            slot.* = .{ .tileset = t, .door = wd.door };
            first_count[wd.to_room] = wd.count;
        }
    }
    return out;
}

/// A script that draws `t`: one that loads it whole, else the first that
/// loads its graphics and metatile table, which is all a picture needs.
pub fn drawingLoader(decoded: door.Decoded, ptrs: []const u8, rows: []const u8, s0: State, t: Tileset) ?u16 {
    if (loaderFor(decoded, ptrs, rows, s0, t)) |l| return l;
    for (1..door.pointer_count) |i| {
        if (screens.scriptOps(decoded, ptrs, i) == null) continue;
        const s, const wr = runScript(decoded, ptrs, rows, s0, @intCast(i), start_count);
        const need = w_bg | w_tiletable;
        if (wr & need == need and s.bg.eql(t.bg) and s.tiletable == t.tiletable) return @intCast(i);
    }
    return null;
}

// ---- The lava, a table per count (1.0 Step 18d) ------------------------------

/// `metatile_pointers` 6-8: `metatiles_lavaCavesEmpty`, `Full` and `Mid`, the
/// three a lava door (`$1E1`-`$1E3`) chooses among by the Metroid count.
pub fn isLavaTable(t: u4) bool {
    return t >= 6 and t <= 8;
}

/// The crawl's walks replayed at another Metroid count (1.0 Step 18d).
///
/// The crawl walked at the new game's count, so a room behind a lava door has
/// the table that door loads at $47. A door script reads the count only
/// through `IF_MET_LESS`, so each arrival's path, back through the doors the
/// crawl walked to the new game or a seed, is run again as scripts at the
/// count asked (`runScript`), and the room takes the lava table its first
/// arrival then leaves: the shortest path, as the crawl walked them. Only the
/// arrivals that left a lava table at the crawl's count: one that left
/// another table can reach lava at a lower count down a path no player
/// takes (`$B:$F1`, through `$B:$E3`, reads Full where the recording shows
/// Mid). What a room shows depends on the door a player came in by, which the
/// ROM does not say (18c2's per-band crawl); the recording's visits this reads
/// wrong stay pinned.
pub const LavaReplay = struct {
    const Key = struct { room: u16, block: [block_len]u8 };

    walked: []const WalkedDoor,
    /// Per arrival (room and what it left loaded), the first door that made it.
    parent: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    /// Per room, the doors into it in the crawl's order.
    into: std.AutoHashMapUnmanaged(u16, std.ArrayList(usize)) = .empty,
    decoded: door.Decoded,
    ptrs: []const u8,
    rows: []const u8,
    rom: []const u8,

    pub fn init(allocator: std.mem.Allocator, rom: []const u8, walked: []const WalkedDoor) !LavaReplay {
        var r: LavaReplay = .{
            .walked = walked,
            .decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData),
            .ptrs = door.pointers(rom) orelse return Error.NoDoorData,
            .rows = thresholds(rom),
            .rom = rom,
        };
        errdefer r.deinit(allocator);
        for (walked, 0..) |wd, i| {
            if (wd.to_room == roster.World.none) continue;
            const g = try r.parent.getOrPut(allocator, .{ .room = wd.to_room, .block = wd.to_block });
            if (!g.found_existing) g.value_ptr.* = i;
            const l = try r.into.getOrPut(allocator, wd.to_room);
            if (!l.found_existing) l.value_ptr.* = .empty;
            try l.value_ptr.append(allocator, i);
        }
        return r;
    }

    pub fn deinit(self: *LavaReplay, allocator: std.mem.Allocator) void {
        var it = self.into.valueIterator();
        while (it.next()) |l| l.deinit(allocator);
        self.into.deinit(allocator);
        self.parent.deinit(allocator);
        self.decoded.deinit(allocator);
    }

    /// What door `i` leaves at `count`: its path back to where the crawl
    /// started or seeded, run forward. A step back goes only to an earlier
    /// door, so a seed later walked into is where its own path starts.
    pub fn arrivalAt(self: LavaReplay, i: usize, count: u8) ?State {
        var path: [1024]usize = undefined;
        var n: usize = 0;
        var at = i;
        while (true) {
            if (n == path.len) return null;
            path[n] = at;
            n += 1;
            const wd = self.walked[at];
            const p = self.parent.get(.{ .room = wd.from_room, .block = wd.from_block }) orelse break;
            if (p >= at) break;
            at = p;
        }
        const t = tilesetOfBlock(self.rom, self.walked[at].from_block) orelse return null;
        var s: State = .{ .bg = t.bg, .spr = .{ .bank = 0, .addr = 0 }, .tiletable = t.tiletable, .collision = t.collision, .solidity = t.solidity, .acid = 0, .spike = 0, .song = 0 };
        var k = n;
        while (k > 0) {
            k -= 1;
            s, _ = runScript(self.decoded, self.ptrs, self.rows, s, self.walked[path[k]].door, count);
        }
        return s;
    }

    /// The lava table `room` shows at `count`: that of its first arrival
    /// that left one at the crawl's count and leaves one at `count`; null
    /// where none does.
    pub fn table(self: LavaReplay, room: u16, count: u8) ?u4 {
        const l = self.into.get(room) orelse return null;
        for (l.items) |i| {
            const walked_t = tilesetOfBlock(self.rom, self.walked[i].to_block) orelse continue;
            if (!isLavaTable(walked_t.tiletable)) continue;
            const s = self.arrivalAt(i, count) orelse continue;
            if (isLavaTable(s.tiletable)) return s.tiletable;
        }
        return null;
    }
};

/// The lava table map bank `bank`'s `cell` shows at `count`, by
/// `LavaReplay`; null where its room is no walked lava room.
pub fn lavaTableAt(allocator: std.mem.Allocator, rom: []const u8, walked: []const WalkedDoor, bank: u8, cell: u8, count: u8) !?u4 {
    var replay = try LavaReplay.init(allocator, rom, walked);
    defer replay.deinit(allocator);
    var w = try roster.world(allocator, rom);
    defer w.deinit(allocator);
    return replay.table(w.roomOf(.{ .bank = bank, .cell = cell }), count);
}

// ---- The static reading, for the crawl ---------------------------------------

/// What the ROM alone says about a room's loaded state, as a door that loads
/// it: the door graph where it settles the room, `screens.assign` otherwise.
/// The crawl seeds rooms it has not walked into with this.
pub const Inference = struct {
    w: roster.World,
    decoded: door.Decoded,
    ptrs: []const u8,
    rows: []const u8,
    s0: State,
    xs: []Crossing,
    st: Settled,
    asg: screens.Assignment,

    pub fn init(allocator: std.mem.Allocator, rom: []const u8, w: roster.World) !Inference {
        var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
        errdefer decoded.deinit(allocator);
        const xs = try crossings(allocator, rom, w, decoded);
        errdefer allocator.free(xs);
        var st = try settle(allocator, rom, w, decoded, xs);
        errdefer st.deinit(allocator);
        return .{
            .w = w,
            .decoded = decoded,
            .ptrs = door.pointers(rom) orelse return Error.NoDoorData,
            .rows = thresholds(rom),
            .s0 = try initialState(rom, decoded),
            .xs = xs,
            .st = st,
            .asg = try screens.assign(allocator, rom),
        };
    }

    pub fn deinit(self: *Inference, allocator: std.mem.Allocator) void {
        self.decoded.deinit(allocator);
        allocator.free(self.xs);
        self.st.deinit(allocator);
        self.asg.deinit(allocator);
    }

    /// A door script that loads `t` whole, lowest index first.
    pub fn loaderOf(self: Inference, t: Tileset) ?u16 {
        return loaderFor(self.decoded, self.ptrs, self.rows, self.s0, t);
    }

    /// The door that loads what the static reading says `p`'s room has.
    pub fn loader(self: Inference, p: roster.Place) ?u16 {
        if (self.st.one(roomAt(self.w, p))) |t| if (self.loaderOf(t)) |l| return l;
        const x = assigned(self.asg, self.decoded, self.ptrs, self.rows, self.s0, drawnCell(self.w, p)) orelse return null;
        return x[1];
    }

    /// What running `chain` from the new game's state leaves, at `count`.
    pub fn run(self: Inference, chain: []const u16, count: u8) State {
        var s = self.s0;
        for (chain) |i| s, _ = runScript(self.decoded, self.ptrs, self.rows, s, i, count);
        return s;
    }

    /// Whether door `index`, run at `count`, loads a whole tileset: what it
    /// leaves then owes nothing to the room it was walked from.
    pub fn loadsTileset(self: Inference, index: u16, count: u8) bool {
        _, const wr = runScript(self.decoded, self.ptrs, self.rows, self.s0, index, count);
        return wr & w_tileset == w_tileset;
    }

    /// Where door `index`'s own `WARP` (or `ENTER_QUEEN`) goes at `count`,
    /// following a branch the count takes. Null for a door that does not warp.
    pub fn warpsTo(self: Inference, index: u16, count: u8) ?roster.Place {
        var at = index;
        var hops: usize = 0;
        var to: ?roster.Place = null;
        outer: while (hops < 8) : (hops += 1) {
            const ops = screens.scriptOps(self.decoded, self.ptrs, at) orelse break;
            for (ops) |op| switch (op) {
                .if_met_less => |x| if (x.met_count >= count) {
                    at = x.transition;
                    continue :outer;
                },
                .warp => |x| to = .{ .bank = x.bank, .cell = x.pos },
                .enter_queen => |q| to = roster.queenCell(q),
                else => {},
            };
            break;
        }
        return to;
    }

    /// The counts `index`'s script, or a branch of it, tests against.
    pub fn thresholdsOf(self: Inference, index: u16, out: *[8]u8) []u8 {
        var n: usize = 0;
        const ops = screens.scriptOps(self.decoded, self.ptrs, index) orelse return out[0..0];
        for (ops) |op| switch (op) {
            .if_met_less => |x| if (n < out.len) {
                out[n] = x.met_count;
                n += 1;
            },
            else => {},
        };
        return out[0..n];
    }
};

// ---- The crawl's result, on disk ---------------------------------------------

/// Bumped whenever the crawl would walk differently, so a stale result is
/// never read: the file name carries it.
pub const crawl_version: u32 = 2;

pub const crawl_dir = "build-out";

/// `build-out/crawl-<first 8 bytes of the ROM's SHA-1>-v<version>.txt`.
pub fn crawlPath(buf: []u8, rom: []const u8) []const u8 {
    var name: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ crawl_dir, crawlName(&name, rom) }) catch unreachable;
}

/// `crawlPath`'s file name alone, for `m2snes --crawl-cache DIR`.
pub fn crawlName(buf: []u8, rom: []const u8) []const u8 {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(rom, &digest, .{});
    return std.fmt.bufPrint(buf, "crawl-{x}-v{d}.txt", .{ digest[0..8], crawl_version }) catch unreachable;
}

/// One line per door, every field hex: from bank, cell, room, truth, block;
/// direction, count, door; to bank, cell, room, truth, block.
pub fn formatWalked(out: *std.Io.Writer, walked: []const WalkedDoor) !void {
    for (walked) |wd| {
        try out.print("{x} {x} {x} {d} {x} {d} {x} {x} {x} {x} {x} {d} {x}\n", .{
            wd.from.bank,         wd.from.cell,              wd.from_room,     @intFromBool(wd.from_truth), wd.from_block[0..],
            @intFromEnum(wd.dir), wd.count,                  wd.door,          wd.to.bank,                  wd.to.cell,
            wd.to_room,           @intFromBool(wd.to_truth), wd.to_block[0..],
        });
    }
}

pub const CrawlError = error{ NoCrawl, BadCrawlLine };

pub fn parseWalked(allocator: std.mem.Allocator, text: []const u8) ![]WalkedDoor {
    var out: std.ArrayList(WalkedDoor) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        var wd: WalkedDoor = undefined;
        const num = struct {
            fn n(comptime T: type, it: *std.mem.TokenIterator(u8, .scalar), base: u8) !T {
                return std.fmt.parseInt(T, it.next() orelse return CrawlError.BadCrawlLine, base) catch CrawlError.BadCrawlLine;
            }
            fn block(it: *std.mem.TokenIterator(u8, .scalar)) ![block_len]u8 {
                const h = it.next() orelse return CrawlError.BadCrawlLine;
                var b: [block_len]u8 = undefined;
                _ = std.fmt.hexToBytes(&b, h) catch return CrawlError.BadCrawlLine;
                return b;
            }
        };
        wd.from = .{ .bank = try num.n(u8, &f, 16), .cell = try num.n(u8, &f, 16) };
        wd.from_room = try num.n(u16, &f, 16);
        wd.from_truth = try num.n(u1, &f, 10) == 1;
        wd.from_block = try num.block(&f);
        wd.dir = @enumFromInt(try num.n(u2, &f, 10));
        wd.count = try num.n(u8, &f, 16);
        wd.door = try num.n(u16, &f, 16);
        wd.to = .{ .bank = try num.n(u8, &f, 16), .cell = try num.n(u8, &f, 16) };
        wd.to_room = try num.n(u16, &f, 16);
        wd.to_truth = try num.n(u1, &f, 10) == 1;
        wd.to_block = try num.block(&f);
        try out.append(allocator, wd);
    }
    return out.toOwnedSlice(allocator);
}

/// The crawl's result for this ROM, as `zig build crawl` left it. The steps
/// that convert depend on that one, so a missing file is a build wired wrong.
pub fn loadWalked(allocator: std.mem.Allocator, rom: []const u8) ![]WalkedDoor {
    var buf: [128]u8 = undefined;
    const path = crawlPath(&buf, rom);
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("warp: {s} is missing; run `zig build crawl`\n", .{path});
            return CrawlError.NoCrawl;
        },
        else => return e,
    };
    defer allocator.free(text);
    return parseWalked(allocator, text);
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the tables a running Game Boy showed, against the walked reading (1.0 Step 18c)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const asg = try assignWalked(a, rom, try loadWalked(a, rom));

    // `screens.zig`'s test of the same name: the tables `oracle -- worlds`
    // read off both published runs. The static reading has ten right and
    // B12's nine wrong; the walk has all of them, each as `.walked`, and
    // `oracle -- worlds` agrees tile for tile at all 34 cells the runs stay in
    // (24 through the static reading). `$A:$00` and `$A:$11` the worlds sweep
    // names 6 and 7: those draw the cell as 8 does, tile for tile.
    const Row = struct { bank: u8, cell: u8, table: u4 };
    const right = [_]Row{
        .{ .bank = 0xC, .cell = 0x41, .table = 4 }, .{ .bank = 0xC, .cell = 0x51, .table = 4 },
        .{ .bank = 0xC, .cell = 0x61, .table = 4 }, .{ .bank = 0xC, .cell = 0x71, .table = 4 },
        .{ .bank = 0xC, .cell = 0x81, .table = 4 }, .{ .bank = 0xF, .cell = 0x6A, .table = 4 },
        .{ .bank = 0xF, .cell = 0x76, .table = 5 }, .{ .bank = 0xA, .cell = 0x44, .table = 4 },
        .{ .bank = 0xA, .cell = 0x48, .table = 4 }, .{ .bank = 0xF, .cell = 0x05, .table = 4 },
        // B12's nine.
        .{ .bank = 0xF, .cell = 0x6B, .table = 4 }, .{ .bank = 0xF, .cell = 0x6C, .table = 4 },
        .{ .bank = 0xC, .cell = 0x21, .table = 4 }, .{ .bank = 0xC, .cell = 0x31, .table = 4 },
        .{ .bank = 0xB, .cell = 0x0D, .table = 8 }, .{ .bank = 0xB, .cell = 0x0E, .table = 8 },
        .{ .bank = 0xA, .cell = 0x00, .table = 8 }, .{ .bank = 0xA, .cell = 0x01, .table = 8 },
        .{ .bank = 0xA, .cell = 0x11, .table = 8 },
    };
    for (right) |r| {
        const ch = asg.find(r.bank, @intCast(r.cell & 0x0F), @intCast(r.cell >> 4)).?.choice.?;
        try testing.expectEqual(r.table, ch.tiletable);
        try testing.expectEqual(screens.Provenance.walked, ch.provenance);
    }

    // The veto re-decided on the walk. On the crawl cached before release
    // Step 0 it was kept in one bank and the walk settled 484 cells; on the
    // committed crawler's, first arrival first, two banks and 558.
    try testing.expectEqual(@as(usize, 2), asg.vetoed_banks);
    try testing.expectEqual(@as(usize, 558), asg.by_provenance[@intFromEnum(screens.Provenance.walked)]);
}

test "the lava tables are the three metatile_pointers sends to lavaCaves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rom = try testrom.load(arena.allocator()) orelse return error.SkipZigTest;
    const e = offsets.find("metatile_pointers").?;
    const t = rom[e.romOffset()..e.romEnd()];
    var lava: [3]u16 = undefined;
    for (&lava, [_][]const u8{ "metatiles_lavaCavesMid", "metatiles_lavaCavesEmpty", "metatiles_lavaCavesFull" }) |*a, name| a.* = offsets.find(name).?.gb_addr;
    for (0..t.len / 2) |i| {
        const ptr = std.mem.readInt(u16, t[i * 2 ..][0..2], .little);
        try testing.expectEqual(std.mem.indexOfScalar(u16, &lava, ptr) != null, isLavaTable(@intCast(i)));
    }
}

test "the crawl's walks replayed at another count (1.0 Step 18d)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const walked = try loadWalked(a, rom);
    var r = try LavaReplay.init(a, rom, walked);
    var w = try roster.world(a, rom);
    _ = &w;

    // Replayed at the count it was walked at, a door leaves the table our
    // Game Boy loaded, but for the few whose path back crosses a seed that
    // was later walked into by another path.
    var differ: usize = 0;
    for (walked, 0..) |wd, i| {
        const s = r.arrivalAt(i, wd.count) orelse continue;
        const t = tilesetOfBlock(rom, wd.to_block) orelse continue;
        differ += @intFromBool(s.tiletable != t.tiletable);
    }
    try testing.expect(differ * 100 < walked.len);

    // The recording's: door $4A leaves Mid at the new game's count and Empty
    // from the first kill (`$B:$0D`, `$A:$11`), and the lowest band's rooms
    // show Empty (`$C:$EB` at $12).
    const Row = struct { bank: u8, cell: u8, count: u8, table: u4 };
    for ([_]Row{
        .{ .bank = 0xB, .cell = 0x0D, .count = 0x47, .table = 8 }, .{ .bank = 0xB, .cell = 0x0D, .count = 0x46, .table = 6 },
        .{ .bank = 0xA, .cell = 0x11, .count = 0x47, .table = 8 }, .{ .bank = 0xA, .cell = 0x11, .count = 0x46, .table = 6 },
        .{ .bank = 0xC, .cell = 0xEB, .count = 0x12, .table = 6 },
    }) |row| try testing.expectEqual(@as(?u4, row.table), r.table(w.roomOf(.{ .bank = row.bank, .cell = row.cell }), row.count));
}

test "every threshold is graded on both sides by a door entry (1.0 Step 18d; $00 since 20d)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const de = try doorEntries(a, rom, try loadWalked(a, rom));
    const counted = try countedEntries(a, rom, de.entries);
    var decoded = try door.decodeRegion(a, door.region(rom).?);
    _ = &decoded;

    // The ROM's thresholds, and the ones a door entry is held to on both
    // sides: at the count, and one above it.
    var all: [256]bool = @splat(false);
    for (decoded.ops.items) |op| switch (op) {
        .if_met_less => |x| all[x.met_count] = true,
        else => {},
    };
    try testing.expectEqual(@as(usize, 13), std.mem.count(bool, &all, &.{true}));
    var missing: std.ArrayList(u8) = .empty;
    for (all, 0..) |t, x| {
        if (!t) continue;
        var both = false;
        for (counted) |e| {
            if (e.count != x) continue;
            for (counted) |f| {
                if (f.chain[f.n - 1] == e.chain[e.n - 1] and f.count == bcdUp(@intCast(x))) both = true;
            }
        }
        if (!both) try missing.append(a, @intCast(x));
    }
    // All thirteen, $00 too since 1.0 Step 20d: door $19E's, whose two sides
    // run `EXIT_QUEEN` (through $19F) into $F:$A9 and `ESCAPE_QUEEN` into
    // $E:$C1.
    try testing.expectEqualSlices(u8, &.{}, missing.items);
    var sides: [2]?roster.Place = .{ null, null };
    for (counted) |e| {
        if (e.chain[e.n - 1] != 0x19E) continue;
        if (e.count == 0x00) sides[0] = e.dest.at;
        if (e.count == 0x01) sides[1] = e.dest.at;
    }
    // Each in its `WARP` cell, or beside it when that cell has no screen:
    // $E:$C1 has none, and she is stood in $E:$B1.
    const w = try roster.world(a, rom);
    try testing.expectEqual(drawnCell(w, .{ .bank = 0xF, .cell = 0xA9 }), sides[0].?);
    try testing.expectEqual(drawnCell(w, .{ .bank = 0xE, .cell = 0xC1 }), sides[1].?);

    // Highest count first, and $01's taken side is her room, through $13B.
    for (counted[1..], counted[0 .. counted.len - 1]) |e, before| try testing.expect(e.count <= before.count);
    const queen = for (counted) |e| {
        if (e.dest.kind == .queen) break e;
    } else return error.NoQueenSide;
    try testing.expectEqual(@as(u8, 0x01), queen.count);
    try testing.expectEqual(@as(u16, 0x13B), queen.chain[queen.n - 1]);
}

test "a walked door survives the crawl file" {
    const wd: WalkedDoor = .{
        .from = .{ .bank = 0xA, .cell = 0x48 },
        .from_room = 11,
        .from_truth = true,
        .from_block = .{ 0x20, 0x59, 0x07, 0x00, 0x58, 0x80, 0x50, 0x80, 0x44, 0x0A, 0x63, 0x5D, 0x63 },
        .dir = .down,
        .count = 0x46,
        .door = 0x52,
        .to = .{ .bank = 0xF, .cell = 0x6A },
        .to_room = 200,
        .to_truth = false,
        .to_block = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try formatWalked(&out.writer, &.{ wd, wd });
    const back = try parseWalked(testing.allocator, out.written());
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualDeep(wd, back[1]);
    try testing.expectError(CrawlError.BadCrawlLine, parseWalked(testing.allocator, "a 48 b 1\n"));
}

test "the cached crawl reads back to the bytes it was written from (release Step 6)" {
    // `m2snes --crawl-cache` builds from the parsed file and the player's run
    // from the crawl in memory. The crawl pin holds the file to
    // `formatWalked(walk)`; this holds `formatWalked(parseWalked(file))` to the
    // file. `formatWalked` writes every field whole, so the two are one value.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    const file = try std.Io.Dir.cwd().readFileAlloc(testing.io, crawlPath(&buf, rom), a, .limited(16 << 20));
    const doors = try parseWalked(a, file);
    var out: std.Io.Writer.Allocating = .init(a);
    try formatWalked(&out.writer, doors);
    try testing.expectEqualStrings(file, out.written());
    try testing.expectEqualDeep(doors, try parseWalked(a, out.written()));
}

test "every destination has a chain that leaves what the Game Boy loaded, or is a finding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const walked = try loadWalked(a, rom);
    const b = try build(a, rom, walked);
    var w = try roster.world(a, rom);
    _ = &w;
    const dests = try roster.destinations(a, rom, w);
    try testing.expectEqual(dests.len, b.entries.len + b.findings.len);
    var decoded = try door.decodeRegion(a, door.region(rom).?);
    _ = &decoded;
    const ptrs = door.pointers(rom).?;
    const rows = thresholds(rom);
    const s0 = try initialState(rom, decoded);
    var by: [4]usize = @splat(0);
    var truncated_differs = false;
    for (b.entries) |e| {
        by[@intFromEnum(e.basis)] += 1;
        var st = s0;
        for (e.chain[0..e.n]) |ci| st, _ = runScript(decoded, ptrs, rows, st, ci, e.count);
        try testing.expect(Tileset.of(st).eql(e.tileset));
        // The fault the scenarios hold the cart to: the last script alone.
        if (e.n == 2 and !Tileset.of(runScript(decoded, ptrs, rows, s0, e.chain[1], e.count)[0]).eql(e.tileset)) truncated_differs = true;
        // She stands where the spot says: in the destination's cell.
        try testing.expect(e.samus_y >> 12 == 0 and e.samus_x >> 12 == 0);
    }
    try testing.expect(truncated_differs);
    // Most are walked on the Game Boy; the crawl is what this step is for.
    try testing.expect(by[@intFromEnum(Basis.walked)] + by[@intFromEnum(Basis.seeded)] > b.entries.len * 3 / 4);
}

test "an entry into a room the Game Boy walked into from truth leaves what truth left" {
    // 1.0 Step 14's playtest: Metroid 01's room (`$A:$17`) drew another room's
    // rock, because its chain was a seeded guess although the crawl had walked
    // door $09A into that room from truth -- and the truth arrival's state has
    // no two-script chain, so `walkedChain` passed it over. Our Game Boy ran
    // the same wrong chain, so the warp rung could not see it; the recording
    // could (kill 27, part 12: `$D808`-`$D814` there is the truth arrival's).
    const a = std.heap.page_allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const walked = try loadWalked(a, rom);
    const b = try build(a, rom, walked);
    var w = try roster.world(a, rom);
    _ = &w;
    // Release Step 0: the two entries `docs/bug_tracker.md` keeps open (Metroid
    // `$A:$36`, item `$A:$37`, accepted as is): a cold crawl walks `$09D` in
    // from truth, and no two-script chain leaves that state.
    const known = [_]struct { kind: roster.Kind, bank: u8, cell: u8 }{
        .{ .kind = .metroid, .bank = 0xA, .cell = 0x36 },
        .{ .kind = .item, .bank = 0xA, .cell = 0x37 },
    };
    var wrong: usize = 0;
    var known_seen: usize = 0;
    for (b.entries) |e| {
        // The recording outranks the crawl: a `.recorded` entry is held to the
        // table the 100% recording showed (1.0 Step 18f), which a truth
        // arrival through another door need not leave.
        if (e.basis == .recorded) continue;
        const room = roomAt(w, e.dest.at);
        // 1.0 Step 18e: a station is entered where it draws its pad, and when
        // no truth arrival does (`$A:$99`'s are through lava) the entry is
        // held to the recording's own save there instead (the test below).
        const pad = if (e.dest.kind == .station) body(rom, w, e.dest.at) else null;
        var any = false;
        var matched = false;
        for (walked) |wd| {
            if (wd.to_room != room or !wd.to_truth or wd.count != e.count) continue;
            const t = tilesetOfBlock(rom, wd.to_block) orelse continue;
            if (pad) |pb| if (roster.stationAt(rom, pb, t.tiletable) == null) continue;
            any = true;
            if (t.eql(e.tileset)) matched = true;
        }
        if (!any or matched) continue;
        if (for (known) |k| {
            if (k.kind == e.dest.kind and k.bank == e.dest.at.bank and k.cell == e.dest.at.cell) break true;
        } else false) {
            known_seen += 1;
            continue;
        }
        wrong += 1;
        std.debug.print("{s} {X}:{X:0>2} ({s}): chain", .{ @tagName(e.dest.kind), e.dest.at.bank, e.dest.at.cell, @tagName(e.basis) });
        for (e.chain[0..e.n]) |ci| std.debug.print(" ${X:0>3}", .{ci});
        std.debug.print(" leaves bg {X}:{X:0>4} solidity {X:0>2}, not a truth arrival's\n", .{ e.tileset.bg.bank, e.tileset.bg.addr, e.tileset.solidity[0] });
    }
    try testing.expectEqual(@as(usize, 0), wrong);
    // The known ones still fail, so fixing the bug says to drop them here.
    try testing.expectEqual(known.len, known_seen);
}

test "every warp stands where a player gets to, in the recording's table (1.0 Step 18f)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const built = try build(a, rom, try loadWalked(a, rom));
    var w = try roster.world(a, rom);
    defer w.deinit(a);
    var decoded = try door.decodeRegion(a, door.region(rom).?);
    _ = &decoded;
    const ptrs = door.pointers(rom).?;
    const rows = thresholds(rom);
    const s0 = try initialState(rom, decoded);
    const recorded = try parseRecorded(a, recorded_tables);

    var held: usize = 0;
    var visited: usize = 0;
    for (built.entries) |e| {
        // Her room's door places her itself (`ENTER_QUEEN`), and she falls in.
        if (e.dest.kind == .queen) continue;
        const cell: roster.Place = .{ .bank = e.dest.at.bank, .cell = @intCast(((e.samus_y >> 8) & 0xF) << 4 | ((e.samus_x >> 8) & 0xF)) };
        const room = w.roomOf(cell);
        var r = try reach(a, rom, w, cell.bank, room, e.tileset);
        if (!r.holds(e.samus_y, e.samus_x)) {
            std.debug.print("{s} {X}:{X:0>2}: ${X:0>4},${X:0>4} is out of reach\n", .{ @tagName(e.dest.kind), e.dest.at.bank, e.dest.at.cell, e.samus_y, e.samus_x });
            return error.OutOfReach;
        }
        // Where the recording stood in the room, its table at its count.
        if (e.dest.kind == .ship) continue;
        const rec = recordedFor(recorded, w, drawnCell(w, e.dest.at), roomAt(w, e.dest.at)) orelse continue;
        visited += 1;
        held += @intFromBool(e.basis == .recorded);
        const t = chainAt(decoded, ptrs, rows, s0, e.chain[0..e.n], rec.count).tiletable;
        if (t != rec.table) {
            std.debug.print("{s} {X}:{X:0>2}: table {d} at ${X:0>2}, the recording's {d}\n", .{ @tagName(e.dest.kind), e.dest.at.bank, e.dest.at.cell, t, rec.count, rec.table });
            return error.NotTheRecordingsTable;
        }
        r.deinit(a);
    }
    // 24 of the 153 visited cells disagreed before; 20 entries moved, the
    // ones in those cells and their rooms' others. The rest were lava rooms
    // drawn at $47's level, which they keep (James, 2026-10-01).
    try testing.expectEqual(@as(usize, 20), held);
    try testing.expect(visited >= 153);

    // No entry needs a count set first: each runs at the live one.
    for (built.entries) |e| if (e.dest.kind != .queen) try testing.expectEqual(start_count, e.count);

    // Metroid 11 as it was (James's playtest, 2026-09-29): caveFirst through
    // $055, $1F0 and her spot at $04C4,$0548, sealed in that rock. Now the
    // lava caves through the area's lava door: lavaCavesMid at $47, the
    // recording's lavaCavesEmpty at its $24.
    const m11 = for (built.entries) |e| {
        if (e.dest.kind == .metroid and e.dest.at.bank == 0xB and e.dest.at.cell == 0x45) break e;
    } else return error.NoMetroid11;
    try testing.expectEqual(@as(u4, 8), m11.tileset.tiletable);
    try testing.expectEqual(@as(u4, 6), chainAt(decoded, ptrs, rows, s0, m11.chain[0..m11.n], 0x24).tiletable);
    const old = Tileset.of(chainAt(decoded, ptrs, rows, s0, &.{ 0x055, 0x1F0 }, start_count));
    try testing.expectEqual(@as(u4, 4), old.tiletable);
    var r_old = try reach(a, rom, w, 0xB, w.roomOf(.{ .bank = 0xB, .cell = 0x45 }), old);
    try testing.expect(!r_old.holds(0x04C4, 0x0548));
    r_old.deinit(a);

    // `$B:$44`'s floor is no way out (James's playtest, 2026-10-01): lava over
    // a blocked edge whose door, `$1AA`, crosses into `$B:$54`'s rock. From
    // that door alone her spot is out of reach; without `lands` it was in.
    var only: std.ArrayList(roster.Edge) = .empty;
    for (w.edges) |e| if (e.from.bank == 0xB and e.from.cell == 0x44 and e.dir == .down) try only.append(a, e);
    try testing.expect(only.items.len > 0);
    var floor_only = w;
    floor_only.edges = only.items;
    var r_floor = try reach(a, rom, floor_only, 0xB, w.roomOf(.{ .bank = 0xB, .cell = 0x45 }), m11.tileset);
    try testing.expect(!r_floor.holds(m11.samus_y, m11.samus_x));
    r_floor.deinit(a);
}

test "every station's warp stands her on its pad (1.0 Step 18e)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const built = try build(a, rom, try loadWalked(a, rom));
    var w = try roster.world(a, rom);
    defer w.deinit(a);

    // The pad drawn under what her chain loads, and her feet on its top in its
    // middle: before the step, `$A:$99`'s chain came in through lava from
    // `$A:$79`, which draws none, and `$E:$54`'s spot was a floor beside it.
    var n: usize = 0;
    for (built.entries) |e| {
        if (e.dest.kind != .station) continue;
        n += 1;
        const b = body(rom, w, e.dest.at).?;
        const m = roster.stationAt(rom, b, e.tileset.tiletable) orelse {
            std.debug.print("{X}:{X:0>2}: no pad under table {d}\n", .{ e.dest.at.bank, e.dest.at.cell, e.tileset.tiletable });
            return error.NoPad;
        };
        try testing.expectEqual((@as(u16, m.row) * 2 + 1) * 8 - feet, e.samus_y & 0xFF);
        try testing.expectEqual(@as(u16, m.col) * 16, e.samus_x & 0xFF);
        try testing.expect(!e.morph);
    }
    try testing.expectEqual(@as(usize, 7), n);

    // `$A:$99` against the recording's save there: part 21, `gbtrace -- <part
    // 21> saves 7000 9000`, the record's `$D808`-`$D814`. All but the enemy
    // page, `$D808`/`$D809`, which no chain loads: the door before leaves it.
    const recorded = [block_len]u8{ 0x20, 0x6D, 0x07, 0x00, 0x58, 0x80, 0x50, 0x80, 0x44, 0x0A, 0x63, 0x5D, 0x63 };
    for (built.entries) |e| {
        if (e.dest.kind != .station or e.dest.at.bank != 0xA or e.dest.at.cell != 0x99) continue;
        try testing.expect(e.tileset.eql(tilesetOfBlock(rom, recorded).?));
        try testing.expectEqual(@as(u16, 0x096C), e.samus_y);
        try testing.expectEqual(@as(u16, 0x09B0), e.samus_x);
        break;
    } else return error.NoStationA99;
}
