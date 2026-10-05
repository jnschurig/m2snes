//! Phase 1's backlog, read out of the ROM (1.0 Step 1).
//!
//! The slice's census came from a recording: every AI James's run dispatched
//! before Alpha 2 died. Phase 1 has to finish the game, and no recording yet
//! covers it, so everything here is derived from the ROM's own tables instead:
//!
//!   * **the AI census**: every AI word any enemy header names, for every
//!     sprite any spawn record in any of the seven map banks places;
//!   * **the Metroid roster**: every spawn record whose AI is a Metroid
//!     species, checked against the count a new game starts from;
//!   * **the warp destinations** the debug screen will offer (C8): save
//!     stations, items, each Metroid's room and the room before it, the
//!     Queen's room and the room before it, and the ship;
//!   * **door-script coverage**: which of the ROM's opcodes the port runs.
//!
//! `zig build roster` prints all of it; `docs/phase1.md` is that printout with
//! the reasoning around it.

const std = @import("std");
const offsets = @import("offsets.zig");
const entity = @import("entity.zig");
const map = @import("map.zig");
const door = @import("door.zig");
const screens = @import("screens.zig");
const save = @import("save.zig");
const items = @import("items.zig");

pub const Error = error{ BadSpawnPointer, UnterminatedSpawnList, BadDoorIndex, NoDoorData };

// ---- Spawn records, the way 03:$422F finds them ---------------------------

/// The AI a sprite id's header names: the trailing word of its 11-byte record.
pub fn aiFor(rom: []const u8, sprite: u8) u16 {
    const hp = offsets.find("enemy_header_pointers").?;
    const hd = offsets.find("enemy_headers").?;
    const ptrs = rom[hp.romOffset()..hp.romEnd()];
    const at = @as(u16, ptrs[@as(usize, sprite) * 2]) | (@as(u16, ptrs[@as(usize, sprite) * 2 + 1]) << 8);
    const rec = rom[hd.romOffset() + (at - hd.gb_addr) ..][0..entity.header_bytes];
    return @as(u16, rec[9]) | (@as(u16, rec[10]) << 8);
}

/// One cell's spawn list, read through `enemy_data_pointers` as the spawn walk
/// reads it, not by walking the data region linearly: the pointer is what the
/// game follows, and a list no pointer names is a list no room spawns.
pub fn cellRecords(rom: []const u8, bank: u8, cell: u8) ![]const [entity.spawn_bytes]u8 {
    const pe = offsets.find("enemy_data_pointers").?;
    const de = offsets.find("enemy_data").?;
    const i = (@as(usize, bank) - map.first_bank) * entity.screens_per_bank + cell;
    const ptr = std.mem.readInt(u16, rom[pe.romOffset() + i * 2 ..][0..2], .little);
    if (ptr < de.gb_addr or ptr >= de.gb_addr + de.size) return Error.BadSpawnPointer;
    const data = rom[de.romOffset()..de.romEnd()];
    const start: usize = ptr - de.gb_addr;
    var end = start;
    while (true) : (end += entity.spawn_bytes) {
        if (end >= data.len) return Error.UnterminatedSpawnList;
        if (data[end] == entity.terminator) break;
    }
    return @ptrCast(data[start..end]);
}

pub const Record = struct {
    bank: u8,
    cell: u8,
    number: u8,
    sprite: u8,
    x: u8,
    y: u8,
    ai: u16,
};

/// Every spawn record in all seven banks, bank then cell then list order.
pub fn allRecords(allocator: std.mem.Allocator, rom: []const u8) ![]Record {
    var out: std.ArrayList(Record) = .empty;
    errdefer out.deinit(allocator);
    var bank: u8 = map.first_bank;
    while (bank <= map.last_bank) : (bank += 1) {
        for (0..map.cells) |c| {
            for (try cellRecords(rom, bank, @intCast(c))) |r| {
                try out.append(allocator, .{
                    .bank = bank,
                    .cell = @intCast(c),
                    .number = r[0],
                    .sprite = r[1],
                    .x = r[2],
                    .y = r[3],
                    .ai = aiFor(rom, r[1]),
                });
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- The AI census --------------------------------------------------------

pub const CensusAi = struct {
    ai: u16,
    /// Spawn records naming it, across every bank.
    records: usize,
    /// Bit `b - 9` set for every map bank `b` it spawns in.
    banks: u8,
    /// The first record's cell, bank then cell order: a room it lives in.
    first: Record,
};

/// Every AI any spawn record reaches, sorted by address.
pub fn census(allocator: std.mem.Allocator, rom: []const u8) ![]CensusAi {
    const recs = try allRecords(allocator, rom);
    defer allocator.free(recs);
    var out: std.ArrayList(CensusAi) = .empty;
    errdefer out.deinit(allocator);
    for (recs) |r| {
        for (out.items) |*a| {
            if (a.ai == r.ai) {
                a.records += 1;
                a.banks |= @as(u8, 1) << @intCast(r.bank - map.first_bank);
                break;
            }
        } else try out.append(allocator, .{
            .ai = r.ai,
            .records = 1,
            .banks = @as(u8, 1) << @intCast(r.bank - map.first_bank),
            .first = r,
        });
    }
    std.mem.sort(CensusAi, out.items, {}, struct {
        fn lt(_: void, a: CensusAi, b: CensusAi) bool {
            return a.ai < b.ai;
        }
    }.lt);
    return out.toOwnedSlice(allocator);
}

/// An AI no spawn record reaches, which a parent installs by writing its
/// address into a child slot or by spawning a header of its own. They are ported with the parent, so the census reaches them
/// through it. `sites` are where the parent's code carries the child's address
/// as an operand in bank 2; the ROM test finds exactly those.
pub const Child = struct { ai: u16, parent: u16, name: []const u8, sites: []const u16 };
pub const children = [_]Child{
    // Once per projectile, 02:$50DE-$5105, at the end of `enAI_blobThrower`.
    .{ .ai = 0x536F, .parent = 0x4EA1, .name = "blobProjectile", .sites = &.{ 0x50E0, 0x50ED, 0x50FA, 0x5107 } },
    // 02:$5B76, in `enAI_drivel`'s spit.
    .{ .ai = 0x5BD4, .parent = 0x5AE2, .name = "drivelSpit", .sites = &.{0x5B77} },
    // `enAI_arachnus.fireballAI`. Not a slot write: Arachnus spawns it from its
    // own long header at 02:$52D2 (`enemy_spawnObject.longHeader`), whose AI
    // word is the site. No spawn record names that header, so the ROM census
    // missed it; the 100% recording dispatched it (1.0 Step 24b, sprites
    // $7B/$7C in $D:$C0).
    .{ .ai = 0x52DF, .parent = 0x5109, .name = "arachnusFireball", .sites = &.{0x52DD} },
};

/// Every `enAI_` routine in bank 2, by M2RoS's label, and the one child AI
/// M2RoS keeps as a local label (`enAI_arachnus.fireballAI`). Names only:
/// nothing here says an AI exists, the census and `children` do. The test
/// below checks the two together name every routine exactly once.
pub const Named = struct { ai: u16, name: []const u8 };
pub const ai_names = [_]Named{
    .{ .ai = 0x4DD3, .name = "itemOrb" },           .{ .ai = 0x4EA1, .name = "blobThrower" },
    .{ .ai = 0x5109, .name = "arachnus" },          .{ .ai = 0x536F, .name = "blobProjectile" },
    .{ .ai = 0x54A1, .name = "glowFly" },           .{ .ai = 0x5542, .name = "rockIcicle" },
    .{ .ai = 0x5651, .name = "NULL" },              .{ .ai = 0x57DE, .name = "crawlerA" },
    .{ .ai = 0x58DE, .name = "crawlerB" },          .{ .ai = 0x59C7, .name = "skreek" },
    .{ .ai = 0x5ABF, .name = "smallBug" },          .{ .ai = 0x5AE2, .name = "drivel" },
    .{ .ai = 0x5BD4, .name = "drivelSpit" },        .{ .ai = 0x5C36, .name = "senjooShirk" },
    .{ .ai = 0x5CE0, .name = "gullugg" },           .{ .ai = 0x5E0B, .name = "chuteLeech" },
    .{ .ai = 0x5F67, .name = "pipeBug" },           .{ .ai = 0x60AB, .name = "skorpVert" },
    .{ .ai = 0x60F8, .name = "skorpHori" },         .{ .ai = 0x6145, .name = "autrack" },
    .{ .ai = 0x61DB, .name = "hopper" },            .{ .ai = 0x62B4, .name = "wallfire" },
    .{ .ai = 0x638C, .name = "gunzoo" },            .{ .ai = 0x6540, .name = "autom" },
    .{ .ai = 0x65D5, .name = "proboscum" },         .{ .ai = 0x6622, .name = "missileBlock" },
    .{ .ai = 0x66F3, .name = "moto" },              .{ .ai = 0x6746, .name = "halzyn" },
    .{ .ai = 0x6841, .name = "septogg" },           .{ .ai = 0x68A0, .name = "flittVanishing" },
    .{ .ai = 0x68FC, .name = "flittMoving" },       .{ .ai = 0x695F, .name = "gravitt" },
    .{ .ai = 0x6A14, .name = "missileDoor" },       .{ .ai = 0x6B83, .name = "metroidStinger" },
    .{ .ai = 0x6BB2, .name = "hatchingAlpha" },     .{ .ai = 0x6C44, .name = "alphaMetroid" },
    .{ .ai = 0x6F60, .name = "gammaMetroid" },      .{ .ai = 0x7276, .name = "zetaMetroid" },
    .{ .ai = 0x7631, .name = "omegaMetroid" },      .{ .ai = 0x7A4F, .name = "normalMetroid" },
    .{ .ai = 0x7BE5, .name = "babyMetroid" },       .{ .ai = 0x52DF, .name = "arachnusFireball" },
};

pub fn nameOf(ai: u16) []const u8 {
    for (ai_names) |n| if (n.ai == ai) return n.name;
    return "?";
}

// ---- The Metroid roster ---------------------------------------------------

/// The AIs whose death takes one off `metroidCountReal`, plus the hatching
/// Alpha, which becomes one. `metroidStinger` (02:$6B83) is **not** here: it
/// is the event that plays the hive song and adds to the *displayed* count,
/// and has a spawn record of its own. The roster test is what says the list is
/// right: with the stinger in, it counts 48 against the ROM's 47.
pub const metroid_species = [_]Named{
    .{ .ai = 0x6BB2, .name = "Alpha (hatching)" },
    .{ .ai = 0x6C44, .name = "Alpha" },
    .{ .ai = 0x6F60, .name = "Gamma" },
    .{ .ai = 0x7276, .name = "Zeta" },
    .{ .ai = 0x7631, .name = "Omega" },
    .{ .ai = 0x7A4F, .name = "larval" },
};

pub fn speciesOf(ai: u16) ?[]const u8 {
    for (metroid_species) |s| if (s.ai == ai) return s.name;
    return null;
}

/// One Metroid in the world. A spawn number is per bank -- each bank's saved
/// flags have their own window -- so `(bank, number)` is its identity, and the
/// roster test holds every record to a distinct one.
pub const Metroid = Record;

pub fn metroids(allocator: std.mem.Allocator, rom: []const u8) ![]Metroid {
    const recs = try allRecords(allocator, rom);
    defer allocator.free(recs);
    var out: std.ArrayList(Metroid) = .empty;
    errdefer out.deinit(allocator);
    for (recs) |r| if (speciesOf(r.ai) != null) try out.append(allocator, r);
    return out.toOwnedSlice(allocator);
}

/// The Queen is the one Metroid with no spawn record: she is `queenHandler`,
/// not an enemy slot.
pub const queen_count: usize = 1;

/// A BCD byte as a number.
pub fn fromBcd(b: u8) usize {
    return @as(usize, b >> 4) * 10 + (b & 0x0F);
}

/// How the roster and the ROM's starting count agree: every record a distinct
/// `(bank, number)`, and the records plus the Queen equal `metroidCountReal`.
pub fn rosterMatches(list: []const Metroid, start_count_bcd: u8) bool {
    for (list, 0..) |a, i| {
        for (list[i + 1 ..]) |b| {
            if (a.bank == b.bank and a.number == b.number) return false;
        }
    }
    return list.len + queen_count == fromBcd(start_count_bcd);
}

/// Our own words for where a cell is: its bank, and which quarter of the
/// bank's 16x16 grid it sits in. The areas the game's fans name are not in the
/// ROM, and this is.
pub fn areaName(buf: []u8, bank: u8, cell: u8) []const u8 {
    const ns: []const u8 = if (cell >> 4 < 8) "north" else "south";
    const we: []const u8 = if (cell & 0x0F < 8) "west" else "east";
    return std.fmt.bufPrint(buf, "bank {X} {s}-{s}", .{ bank, ns, we }) catch unreachable;
}

// ---- Rooms and the door graph ---------------------------------------------

/// A cell's door index is its word in the bank's transition table with the
/// sprite-priority bit cleared: `RES 3,A` on the high byte at 00:$0C6E.
pub const door_priority_mask: u16 = 0x0800;

pub fn doorIndex(word: u16) u16 {
    return word & ~door_priority_mask;
}

pub const Dir = enum(u2) {
    right,
    left,
    up,
    down,

    /// The neighbour one screen over. The screen coordinates are four bits
    /// each, so the grid wraps (`docs/slice.md`, "a cell's out-edges").
    pub fn step(self: Dir, cell: u8) ?u8 {
        const x: u8 = cell & 0x0F;
        const y: u8 = cell >> 4;
        return switch (self) {
            .right => (y << 4) | ((x + 1) & 0x0F),
            .left => (y << 4) | ((x -% 1) & 0x0F),
            .up => (((y -% 1) & 0x0F) << 4) | x,
            .down => (((y + 1) & 0x0F) << 4) | x,
        };
    }

    pub fn blocks(self: Dir, s: map.Scroll) bool {
        return switch (self) {
            .right => s.block_right,
            .left => s.block_left,
            .up => s.block_up,
            .down => s.block_down,
        };
    }
};

pub const Place = struct { bank: u8, cell: u8 };

/// Where a door goes. `queen` is set when the script (or a branch it can take)
/// runs `ENTER_QUEEN`; `station` when the path to it runs `ITEM $0`, which
/// loads the save station's graphics (`items.Id.save`), and `collision` is the
/// last `COLLISION` operand on that path, if it names one.
pub const Dest = struct { to: Place, queen: bool = false, station: bool = false, collision: ?u4 = null, tiletable: ?u4 = null };

/// One crossing: leaving `from` in `dir` runs door `index`.
pub const Edge = struct { from: Place, dir: Dir, index: u16, dest: Dest };

pub const World = struct {
    banks: [map.bank_count]map.Bank,
    /// Room id per cell: in-use cells joined wherever the camera may scroll
    /// across the shared edge (neither side blocks it). Blank cells are `none`.
    room: [map.bank_count][map.cells]u16,
    edges: []Edge,

    pub const none: u16 = 0xFFFF;

    pub fn deinit(self: *World, allocator: std.mem.Allocator) void {
        for (&self.banks) |*b| b.deinit(allocator);
        allocator.free(self.edges);
    }

    pub fn roomOf(self: World, p: Place) u16 {
        return self.room[p.bank - map.first_bank][p.cell];
    }

    pub fn cellOf(self: World, p: Place) map.Cell {
        return self.banks[p.bank - map.first_bank].cells[p.cell];
    }
};

/// The destinations a script can reach: its own `WARP`, or with none the cell
/// past the crossing, and the same for every `IF_MET_LESS` branch it can take
/// (a threshold picks one; the door graph keeps them all).
fn scriptDests(
    allocator: std.mem.Allocator,
    decoded: door.Decoded,
    ptrs: []const u8,
    index: u16,
    past: ?Place,
    out: *std.ArrayList(Dest),
    depth: usize,
) !void {
    if (depth > 8) return;
    const ops = screens.scriptOps(decoded, ptrs, index) orelse return;
    var warped = false;
    var st = false;
    var coll: ?u4 = null;
    var tt: ?u4 = null;
    for (ops) |op| switch (op) {
        .item => |v| st = st or v == @intFromEnum(items.Id.save),
        .collision => |v| coll = v,
        .tiletable => |v| tt = v,
        .warp => |w| {
            try out.append(allocator, .{ .to = .{ .bank = w.bank, .cell = w.pos }, .station = st, .collision = coll, .tiletable = tt });
            warped = true;
        },
        .enter_queen => |q| {
            try out.append(allocator, .{ .to = queenCell(q), .queen = true });
            warped = true;
        },
        .if_met_less => |m| try scriptDests(allocator, decoded, ptrs, m.transition, past, out, depth + 1),
        else => {},
    };
    if (!warped) if (past) |p| try out.append(allocator, .{ .to = p, .station = st, .collision = coll, .tiletable = tt });
}

/// `ENTER_QUEEN` carries a world scroll rather than a cell; its high bytes are
/// the screen coordinates, as `screens.assign` reads them.
pub fn queenCell(q: anytype) Place {
    const pos: u8 = @as(u8, @truncate(q.scroll_y >> 8)) *% 16 +% @as(u8, @truncate(q.scroll_x >> 8));
    return .{ .bank = q.bank, .cell = pos };
}

pub fn world(allocator: std.mem.Allocator, rom: []const u8) !World {
    var w: World = .{ .banks = undefined, .room = @splat(@splat(World.none)), .edges = &.{} };
    var parsed: usize = 0;
    errdefer for (w.banks[0..parsed]) |*b| b.deinit(allocator);
    while (parsed < map.bank_count) : (parsed += 1) {
        w.banks[parsed] = try map.parseBank(allocator, rom, map.first_bank + @as(u8, @intCast(parsed)));
    }

    // Rooms: flood fill over scrollable edges.
    var next: u16 = 0;
    for (0..map.bank_count) |bi| {
        const cells = &w.banks[bi].cells;
        for (0..map.cells) |start| {
            if (!cells[start].inUse() or w.room[bi][start] != World.none) continue;
            var stack: std.ArrayList(u8) = .empty;
            defer stack.deinit(allocator);
            try stack.append(allocator, @intCast(start));
            w.room[bi][start] = next;
            while (stack.pop()) |c| {
                for ([_]Dir{ .right, .left, .up, .down }) |d| {
                    const n = d.step(c) orelse continue;
                    if (!cells[n].inUse() or w.room[bi][n] != World.none) continue;
                    const back: Dir = switch (d) {
                        .right => .left,
                        .left => .right,
                        .up => .down,
                        .down => .up,
                    };
                    if (d.blocks(cells[c].scroll) or back.blocks(cells[n].scroll)) continue;
                    w.room[bi][n] = next;
                    try stack.append(allocator, n);
                }
            }
            next += 1;
        }
    }

    // Doors: a crossing starts where the camera is blocked and Samus walks on
    // (00:$0835's four edge checks), and runs the camera cell's script.
    var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(allocator);
    var dests: std.ArrayList(Dest) = .empty;
    defer dests.deinit(allocator);
    for (0..map.bank_count) |bi| {
        const bank: u8 = map.first_bank + @as(u8, @intCast(bi));
        for (w.banks[bi].cells, 0..) |c, ci| {
            if (!c.inUse()) continue;
            // Index 0 is a held crossing with no script (00:$239C returns at
            // once): the camera stops, the next screen is drawn, and she walks on.
            const index = doorIndex(c.transition);
            if (index >= door.pointer_count) return Error.BadDoorIndex;
            for ([_]Dir{ .right, .left, .up, .down }) |d| {
                if (!d.blocks(c.scroll)) continue;
                const past: ?Place = if (d.step(@intCast(ci))) |n| .{ .bank = bank, .cell = n } else null;
                dests.clearRetainingCapacity();
                if (index == 0) {
                    if (past) |p| try dests.append(allocator, .{ .to = p });
                } else try scriptDests(allocator, decoded, ptrs, index, past, &dests, 0);
                for (dests.items) |dst| try edges.append(allocator, .{
                    .from = .{ .bank = bank, .cell = @intCast(ci) },
                    .dir = d,
                    .index = index,
                    .dest = dst,
                });
            }
        }
    }
    // A warp can name a blank cell: the operand is the camera's screen, and
    // Samus's offset within it can put the screen drawn one cell on
    // (`screens.assign`'s `handed_to_neighbour`). Such a target goes to the
    // in-use cell one step on in the crossing's direction.
    for (edges.items) |*e| {
        const t = e.dest.to;
        if (t.bank < map.first_bank or t.bank > map.last_bank) continue;
        if (w.cellOf(t).inUse()) continue;
        const n = e.dir.step(t.cell) orelse continue;
        if (w.cellOf(.{ .bank = t.bank, .cell = n }).inUse()) e.dest.to.cell = n;
    }
    w.edges = try edges.toOwnedSlice(allocator);
    return w;
}

// ---- Warp destinations ----------------------------------------------------

/// `door` is none of the WARP page's: the `doors` rung's case carts (1.0 Step 18a)
/// put every door script on a list of their own.
pub const Kind = enum { station, item, metroid, metroid_before, queen, queen_before, ship, door };

pub const Destination = struct {
    kind: Kind,
    at: Place,
    /// The door crossed to get from here to the target, for the `_before`
    /// kinds; the door index the chain will start from, in Step 5.
    door: ?u16 = null,
    /// What is there: the item, or the Metroid's record.
    item: ?items.Collected = null,
    metroid: ?Metroid = null,
    /// An item's spawn record: where the orb is in its cell.
    record: ?Record = null,
    /// For a station: the tileset `screens.assign` gave the cell, and how
    /// sure it was.
    choice: ?screens.Choice = null,
};

/// The collision table that goes with a metatile table, by name: each
/// tileset's two tables share a suffix, and the three lava metatile tables
/// share one collision table.
pub fn collisionFor(rom: []const u8, tt: u4) ?[]const u8 {
    if (tt >= screens.tiletable_order.len) return null;
    const mt = screens.tiletable_order[tt];
    const suffix = mt["metatiles_".len..];
    var buf: [48]u8 = undefined;
    const base = if (std.mem.startsWith(u8, suffix, "lavaCaves")) "lavaCaves" else suffix;
    const name = std.fmt.bufPrint(&buf, "collision_{s}", .{base}) catch return null;
    const e = offsets.find(name) orelse return null;
    if (e.romEnd() > rom.len) return null;
    return rom[e.romOffset()..e.romEnd()];
}

/// The collision byte's save-station bit (`BIT 7,A`, 00:$1F4F).
pub const block_save: u8 = 0x80;

fn isSave(coll: []const u8, tile: u8) bool {
    return tile != 0xFF and coll[tile] & block_save != 0;
}

/// Whether a screen body, drawn with tiletable `tt`, has a save station: a
/// metatile whose bottom row is save-bit tiles directly above one whose top row
/// is, so the pad Samus stands on is whole across the seam. Every tileset that
/// has a station draws it that way (caveFirst `$45` over `$46`, ruinsInside
/// `$28` over `$29`, plantBubbles `$60` over `$61`). One save-bit tile is not
/// enough: the tileset is `screens.assign`'s, which is inference on scrolled
/// cells, and a surface cell read as caveFirst turns up tile `$10` in dozens
/// of places a station is not.
fn hasStation(rom: []const u8, body: []const u8, tt: u4) bool {
    return stationAt(rom, body, tt) != null;
}

/// Where the station is: the metatile row and column of its upper half.
pub const MetatileAt = struct { row: u8, col: u8 };

pub fn stationAt(rom: []const u8, body: []const u8, tt: u4) ?MetatileAt {
    const mts = screens.metatileTable(rom, tt) orelse return null;
    const coll = collisionFor(rom, tt) orelse return null;
    for (0..map.grid_h - 1) |r| {
        for (0..map.grid_w) |c| {
            const top = @as(usize, body[r * map.grid_w + c]) * 4;
            const bot = @as(usize, body[(r + 1) * map.grid_w + c]) * 4;
            if (top + 4 > mts.len or bot + 4 > mts.len) continue;
            if (isSave(coll, mts[top + 2]) and isSave(coll, mts[top + 3]) and
                isSave(coll, mts[bot]) and isSave(coll, mts[bot + 1])) return .{ .row = @intCast(r), .col = @intCast(c) };
        }
    }
    return null;
}

/// `enAI_arachnus`.
pub const arachnus_ai: u16 = 0x5109;

pub fn destinations(allocator: std.mem.Allocator, rom: []const u8, w: World) ![]Destination {
    var out: std.ArrayList(Destination) = .empty;
    errdefer out.deinit(allocator);

    // Save stations, from the converted screens under the tileset
    // `screens.assign` gives each cell.
    var asg = try screens.assign(allocator, rom);
    defer asg.deinit(allocator);
    for (asg.cells) |c| {
        const choice = c.choice orelse continue;
        const bi = c.bank - map.first_bank;
        const cell = w.banks[bi].cells[@as(usize, c.y) * 16 + c.x];
        const off = cell.screenOffsetInBank() orelse continue;
        const body = rom[@as(usize, c.bank) * offsets.bank_size + off ..][0..map.screen_bytes];
        if (hasStation(rom, body, choice.tiletable)) try out.append(allocator, .{
            .kind = .station,
            .at = .{ .bank = c.bank, .cell = @as(u8, c.y) * 16 + c.x },
            .choice = choice,
        });
    }

    // Items: the orb's records, even ids, and the bare items, odd.
    const recs = try allRecords(allocator, rom);
    defer allocator.free(recs);
    for (recs) |r| {
        if (r.ai != 0x4DD3) continue;
        const it = items.collectedFor(r.sprite | 1) orelse continue;
        try out.append(allocator, .{ .kind = .item, .at = .{ .bank = r.bank, .cell = r.cell }, .item = it, .record = r });
    }
    // 1.0 Step 13: the Spring Ball, which no orb record carries -- Arachnus
    // turns into it (02:$5256) -- so its destination is Arachnus's record.
    for (recs) |r| {
        if (r.ai != arachnus_ai) continue;
        try out.append(allocator, .{ .kind = .item, .at = .{ .bank = r.bank, .cell = r.cell }, .item = .spring_ball, .record = r });
    }

    // Each Metroid, and the room a door enters its room from.
    for (recs) |r| {
        if (speciesOf(r.ai) == null) continue;
        const here: Place = .{ .bank = r.bank, .cell = r.cell };
        try out.append(allocator, .{ .kind = .metroid, .at = here, .metroid = r });
        if (entryInto(w, w.roomOf(here), false)) |e| {
            try out.append(allocator, .{ .kind = .metroid_before, .at = e.from, .door = e.index, .metroid = r });
        }
    }

    // The Queen: where `ENTER_QUEEN` lands, and the doors that run it.
    var queen_added = false;
    for (w.edges) |e| {
        if (!e.dest.queen) continue;
        if (!queen_added) {
            try out.append(allocator, .{ .kind = .queen, .at = e.dest.to });
            queen_added = true;
        }
        try out.append(allocator, .{ .kind = .queen_before, .at = e.from, .door = e.index });
        break;
    }

    // The ship: where a new game's record starts.
    const init = save.initial(rom) orelse return Error.NoDoorData;
    try out.append(allocator, .{ .kind = .ship, .at = .{ .bank = init.level_bank, .cell = init.cell() } });

    return out.toOwnedSlice(allocator);
}

/// The first door, bank then cell order, that leads into `room` from outside
/// it. Null when no door does, which is a finding rather than an absence.
pub fn entryInto(w: World, room: u16, queen: bool) ?Edge {
    for (w.edges) |e| {
        if (e.dest.queen != queen) continue;
        if (e.dest.to.bank < map.first_bank or e.dest.to.bank > map.last_bank) continue;
        if (w.roomOf(e.dest.to) != room) continue;
        if (w.roomOf(e.from) == room) continue;
        return e;
    }
    return null;
}

// ---- Door-script coverage -------------------------------------------------

/// What the port does with each opcode, by high nibble. The engine's dispatch
/// in `StepDoorScript` has an arm for most (`arm`). `LOAD` never reaches it,
/// because the builder rewrites it as a `COPY` (`converted`). `FADEOUT` goes
/// down the skip-by-length path, and its frames are waited out
/// (`OpExtraFrames`); the palette steps run a frame at a time off that wait,
/// as 00:$2561's loop does (Step 20) (`waited`). `ENTER_QUEEN` acts since 1.0
/// Step 6, and `ESCAPE_QUEEN` and `EXIT_QUEEN` since 1.0 Step 20d. Nothing is
/// `skipped` now; the value stays for an opcode a later ROM reading finds.
pub const Handling = enum { arm, converted, waited, skipped };

pub fn handling(tag: std.meta.Tag(door.Op)) Handling {
    return switch (tag) {
        .copy, .tiletable, .collision, .solidity, .warp, .damage, .if_met_less, .song, .item, .end, .enter_queen, .escape_queen, .exit_queen => .arm,
        .load => .converted,
        .fadeout => .waited,
    };
}

pub const OpUse = struct {
    tag: std.meta.Tag(door.Op),
    /// Scripts, of the 512, whose own ops (not a branch's) include it.
    scripts: usize = 0,
    first: ?u16 = null,
};

pub const Coverage = struct {
    uses: [std.meta.fields(door.Op).len]OpUse,
    /// Pointers that land on an operation boundary.
    decoded: usize,
    /// Scripts whose pointer does not: past the end, or into free space.
    undecodable: usize,
};

pub fn coverage(allocator: std.mem.Allocator, rom: []const u8) !Coverage {
    var decoded = try door.decodeRegion(allocator, door.region(rom) orelse return Error.NoDoorData);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom) orelse return Error.NoDoorData;
    var cov: Coverage = .{ .uses = undefined, .decoded = 0, .undecodable = 0 };
    inline for (std.meta.fields(door.Op), 0..) |f, i| cov.uses[i] = .{ .tag = @field(std.meta.Tag(door.Op), f.name) };
    for (0..door.pointer_count) |i| {
        const ops = screens.scriptOps(decoded, ptrs, i) orelse {
            cov.undecodable += 1;
            continue;
        };
        cov.decoded += 1;
        var seen: [std.meta.fields(door.Op).len]bool = @splat(false);
        for (ops) |op| seen[@intFromEnum(std.meta.activeTag(op))] = true;
        for (seen, 0..) |s, k| if (s) {
            cov.uses[k].scripts += 1;
            if (cov.uses[k].first == null) cov.uses[k].first = @intCast(i);
        };
    }
    return cov;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "every bank-2 AI is in the census or a named child, and nowhere else" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const cen = try census(testing.allocator, rom);
    defer testing.allocator.free(cen);
    for (ai_names) |n| {
        var hits: usize = 0;
        for (cen) |c| hits += @intFromBool(c.ai == n.ai);
        for (children) |c| hits += @intFromBool(c.ai == n.ai);
        if (hits != 1) std.debug.print("02:{X:0>4} {s}: {d} hits\n", .{ n.ai, n.name, hits });
        try testing.expectEqual(@as(usize, 1), hits);
    }
    for (cen) |c| try testing.expect(!std.mem.eql(u8, nameOf(c.ai), "?"));
    try testing.expectEqual(ai_names.len, cen.len + children.len);
}

test "a child's address is an operand in its parent's code, at the sites named" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const b2 = rom[2 * offsets.bank_size ..][0..offsets.bank_size];
    for (children) |c| {
        var found: std.ArrayList(u16) = .empty;
        defer found.deinit(testing.allocator);
        var i: usize = 0;
        while (i + 1 < b2.len) : (i += 1) {
            if (std.mem.readInt(u16, b2[i..][0..2], .little) == c.ai) try found.append(testing.allocator, @intCast(0x4000 + i));
        }
        try testing.expectEqualSlices(u16, c.sites, found.items);
        // And every site is inside the parent: past its entry, before the
        // next routine after it.
        var end: u16 = 0x8000;
        for (ai_names) |n| if (n.ai > c.parent and n.ai < end) {
            end = n.ai;
        };
        for (c.sites) |site| try testing.expect(site > c.parent and site < end);
    }
}

test "the roster plus the Queen is the count a new game starts from" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const list = try metroids(testing.allocator, rom);
    defer testing.allocator.free(list);
    const init = save.initial(rom).?;
    try testing.expectEqual(@as(u8, 0x47), init.metroid_count_real);
    try testing.expect(rosterMatches(list, init.metroid_count_real));
    // It fails with a record dropped, and with the stinger counted in.
    try testing.expect(!rosterMatches(list[1..], init.metroid_count_real));
    const recs = try allRecords(testing.allocator, rom);
    defer testing.allocator.free(recs);
    var with_stinger: std.ArrayList(Metroid) = .empty;
    defer with_stinger.deinit(testing.allocator);
    try with_stinger.appendSlice(testing.allocator, list);
    for (recs) |r| if (r.ai == 0x6B83) try with_stinger.append(testing.allocator, r);
    try testing.expect(with_stinger.items.len > list.len);
    try testing.expect(!rosterMatches(with_stinger.items, init.metroid_count_real));
}

test "every cell's door index names a script, and the Queen has a way in" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    var w = try world(testing.allocator, rom);
    defer w.deinit(testing.allocator);
    var queen: usize = 0;
    for (w.edges) |e| queen += @intFromBool(e.dest.queen);
    try testing.expect(queen > 0);
}

test "destinations: a station, every item record, every Metroid, the Queen and the ship" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    var w = try world(testing.allocator, rom);
    defer w.deinit(testing.allocator);
    const d = try destinations(testing.allocator, rom, w);
    defer testing.allocator.free(d);
    var n: [std.meta.fields(Kind).len]usize = @splat(0);
    for (d) |x| n[@intFromEnum(x.kind)] += 1;
    try testing.expect(n[@intFromEnum(Kind.station)] > 0);
    try testing.expectEqual(@as(usize, 46), n[@intFromEnum(Kind.metroid)]);
    try testing.expectEqual(@as(usize, 1), n[@intFromEnum(Kind.queen)]);
    try testing.expectEqual(@as(usize, 1), n[@intFromEnum(Kind.ship)]);
    // Every station is in a cell that is drawn, under a tileset that has one.
    for (d) |x| if (x.kind == .station) {
        try testing.expect(w.cellOf(x.at).inUse());
        try testing.expect(collisionFor(rom, x.choice.?.tiletable) != null);
    };
}

test "a station is two save-bit metatiles meeting at the seam, and not one tile" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const cave: u4 = 4; // `metatiles_caveFirst`, whose station is $45 over $46
    try testing.expectEqualStrings("metatiles_caveFirst", screens.tiletable_order[cave]);
    var body: [map.screen_bytes]u8 = @splat(0x08);
    try testing.expect(!hasStation(rom, &body, cave));
    body[5 * 16 + 5] = 0x45;
    try testing.expect(!hasStation(rom, &body, cave)); // half a station
    body[6 * 16 + 5] = 0x46;
    try testing.expect(hasStation(rom, &body, cave));
    body[5 * 16 + 5] = 0x46;
    body[6 * 16 + 5] = 0x45;
    try testing.expect(!hasStation(rom, &body, cave)); // upside down
}

test "door coverage: no opcode is skipped (1.0 Step 20d)" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const cov = try coverage(testing.allocator, rom);
    for (cov.uses) |u| {
        if (u.scripts == 0) continue;
        const h = handling(u.tag);
        try testing.expect(h != .skipped);
    }
    try testing.expectEqual(door.pointer_count, cov.decoded + cov.undecodable);
}
