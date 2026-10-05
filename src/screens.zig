//! Which tileset draws each map screen, and how a screen becomes pixels.
//!
//! Nothing in the ROM's map data says which graphics a screen uses. The map
//! banks hold metatile indexes and nothing else. The door scripts are what
//! actually load a room -- a script copies graphics into VRAM, selects a
//! metatile table, then warps to a bank and grid position -- so a warp target
//! is a screen whose tileset the ROM states outright. There are 252 of those,
//! against 905 screens in use. Everything else is reached by *scrolling*, and
//! the tileset simply persists from wherever the player came in.
//!
//! That gap is a real limit of the ROM's data, not an oversight here, and
//! Step 7 established how real by reading the engine rather than guessing at
//! it. The `WARP` operand is exactly a grid cell -- the handler at bank 0
//! $28FB writes its high nibble to the screen row and its low nibble to the
//! screen column, and $0835 forms `row * 16 + col` to index the map bank's
//! pointer table. Both halves are re-derived from the ROM by the tests at the
//! bottom of this file, and all 512 door scripts were executed on a booted
//! machine to confirm it: 369 loaded a screen and every one read the cell the
//! operand named. What the ROM does *not* carry is Samus's offset within that
//! screen, and the camera is derived from her full position, so the screen
//! actually drawn can be one cell off. Nothing recovers that statically.
//!
//! Rather than paper over the gap with one confident-looking answer, every
//! screen carries the `Provenance` of its assignment:
//!
//!   `door`    - a warp targeted this exact cell. Stated by the ROM.
//!   `scrolled`- nearest warp target by grid distance within the same connected
//!               region. Inference, and right wherever a region is one area.
//!   `bank`    - no warp reaches this region at all; the bank's most common
//!               tileset stands in. A guess, counted and named as one.
//!
//! Step 9 diffs converted renders against these frames, and that comparison is
//! valid at every provenance -- both sides read the same pairing, so a quadrant
//! or orientation error still fails. What provenance governs is how much a
//! *picture* is worth to a human reviewing it, which is why it is in the
//! manifest instead of hidden.
//!
//! Two checks stay gates regardless. Screens reached from two different doors
//! must agree, and every metatile index a screen uses must resolve inside the
//! table it was assigned.
//!
//! VRAM is modelled explicitly instead of assumed. Tile ids are read through
//! the $8800 signed addressing mode -- id $00-$7F from $9000, id $80-$FF from
//! $8800 -- which is not a guess: `COPY_data gfx_commonItems, $8F00, $0100`
//! puts a 16-tile block exactly where ids $F0-$FF address, and `surface`'s
//! highest metatile id is $EF, one tile below it.

const std = @import("std");
const offsets = @import("offsets.zig");
const map = @import("map.zig");
const disasm = @import("gb/disasm.zig");
const door = @import("door.zig");
const tileset = @import("tileset.zig");
const gfx = @import("gfx.zig");

/// A screen is 16x16 metatiles of 16x16 pixels.
pub const screen_px: usize = map.grid_w * 16;
pub const screen_pixels: usize = screen_px * screen_px;

/// Where `LOAD_bg` and `LOAD_spr` put their source, and how much they move.
///
/// The opcode carries neither, so both are fixed in the handler at 0:$26EB,
/// which fills the same six-byte VRAM request block at $FFB1-$FFB6 that `COPY`
/// streams its operands into: src lo/hi, dest lo/hi, len lo/hi. `COPY`'s
/// handler at 0:$2747 writes those six in exactly the order `door.zig` decodes
/// them, which is what fixes the block's field order without having to assume
/// it. Read off the two `LOAD` paths:
///
///     LOAD_bg  ($B1)   dest $9000, len $0800
///     LOAD_spr ($B2)   dest $8B00, len $0400
///
/// Both of these were wrong here until Step 8 disassembled the handler, and the
/// errors were not cosmetic. SPR was $8000, which is outside the background's
/// signed window entirely, so a sprite load could never supply a background
/// tile - and `metatiles_surface` reaches id $EF and `metatiles_queen` id $FE,
/// both of which live in the $8B00 blob. Length came from the source entry's
/// own size, which under-reads the three $530 lavaCaves blobs by $2D0 relative
/// to the hardware. The hardware over-reads past the entry into whatever
/// follows it in the bank, and reproducing that is the point: the frames are
/// meant to be what the Game Boy draws, not what a tidier engine would.
pub const load_bg_dest: u16 = 0x9000;
pub const load_spr_dest: u16 = 0x8B00;
pub const load_bg_len: u16 = 0x0800;
pub const load_spr_len: u16 = 0x0400;

/// The `TILETABLE` operand indexes this list.
///
/// It is `metatilePointerTable` (08:$7F1A, `metatile_pointers`) written out
/// by name, and `a TILETABLE operand selects the table the ROM's pointer table
/// names` holds it to the ROM. Layout order is not the operand order in two
/// places: slots 0-2 (`finalLab` is physically third), and the three lava
/// tables, where the ROM says Empty, Full, Mid.
///
/// **The lava slots were layout order, Mid/Empty/Full, until 2026-09-24.** The
/// graphics test below could not see it, because all three lava tables go with
/// the same graphics, and the cart drew every lava room one acid level high:
/// Full before the first kill where the Game Boy has Mid, and Mid after it
/// where the Game Boy has none. `docs/bug_tracker.md`, the acid entries.
pub const tiletable_order = [_][]const u8{
    "metatiles_finalLab", // 0
    "metatiles_ruinsInside", // 1
    "metatiles_plantBubbles", // 2
    "metatiles_queen", // 3
    "metatiles_caveFirst", // 4
    "metatiles_surface", // 5
    "metatiles_lavaCavesEmpty", // 6
    "metatiles_lavaCavesFull", // 7
    "metatiles_lavaCavesMid", // 8
    "metatiles_ruinsExt", // 9
};


/// How much the ROM actually said about a screen's tileset.
pub const Provenance = enum {
    door,
    /// 1.0 Step 18c: what our Game Boy had loaded on walking into the cell's
    /// room from the new game (`warp.assignWalked`). Measured, not inferred.
    walked,
    inherited,
    scrolled,
    bank,

    pub fn label(self: Provenance) []const u8 {
        return switch (self) {
            .door => "stated by a door warp",
            .walked => "what our Game Boy loaded walking in",
            .inherited => "carried through a door that named no table",
            .scrolled => "nearest warp target in the same region",
            .bank => "the bank's most common tileset -- a guess",
        };
    }
};

/// What a door script had loaded by the time it warped.
pub const Choice = struct {
    door_index: u16,
    tiletable: u4,
    bg_gfx: ?[]const u8 = null,
    provenance: Provenance = .door,
    /// Grid steps from the warp target this was inherited from. Zero for a
    /// screen a door named directly.
    distance: u8 = 0,

    pub fn eql(a: Choice, b: Choice) bool {
        if (a.tiletable != b.tiletable) return false;
        const ag = a.bg_gfx orelse "";
        const bg_ = b.bg_gfx orelse "";
        return std.mem.eql(u8, ag, bg_);
    }
};

pub const Error = error{ NoSuchEntry, BadTiletable } || door.Error || map.Error || tileset.Error;

/// One screen's worth of assignment: bank, grid position, and the body's
/// address within the bank.
pub const Cell = struct {
    bank: u8,
    x: u4,
    y: u4,
    screen_ptr: u16,
    choice: ?Choice,
};

pub const Assignment = struct {
    cells: []Cell,
    /// Warp targets whose two doors disagreed about the tileset.
    conflicts: usize,
    /// In-use cells in total.
    in_use: usize,
    /// Per-provenance cell counts, indexed by `@intFromEnum`.
    by_provenance: [@typeInfo(Provenance).@"enum".fields.len]usize,
    /// Scrolled cells whose two nearest warp targets, at equal distance,
    /// named different tilesets. The honest measure of how much the nearest-
    /// seed rule is being asked to decide.
    ambiguous: usize,
    /// Doors that warped without ever selecting a metatile table -- they
    /// inherit the previous room's, so they seed nothing.
    inheriting_doors: usize,
    /// Warps that landed on a filler cell and were handed to its single in-use
    /// neighbour. See the comment in `assign`: the camera can be one cell off
    /// the cell the operand names, and never more than one.
    handed_to_neighbour: usize,
    /// Targets seeded from the room a table-less door was entered from, rather
    /// than from a table the door named. See `inheritSeeds`.
    inherited_seeds: usize,
    /// Banks where those seeds were thrown away again because they made the
    /// bank's screens flatter by `collapsedPairs`. Two: bank $9, from 0
    /// collapsed pairs to 49, and bank $A, from 0 to 100.
    vetoed_banks: usize,

    pub fn deinit(self: *Assignment, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }

    pub fn find(self: Assignment, bank: u8, x: u4, y: u4) ?Cell {
        for (self.cells) |c| {
            if (c.bank == bank and c.x == x and c.y == y) return c;
        }
        return null;
    }
};

/// Walk every door script, seed its warp target, then spread each seed
/// outward to the screens you can only reach by scrolling.
pub fn assign(allocator: std.mem.Allocator, rom: []const u8) !Assignment {
    return assignWith(allocator, rom, .{});
}

pub const Options = struct {
    /// Throw the inheritance pass away in a bank it makes flatter
    /// (`collapsedPairs`). Off only to measure the veto against.
    veto: bool = true,
};

pub fn assignWith(allocator: std.mem.Allocator, rom: []const u8, opts: Options) !Assignment {
    var cells: std.ArrayList(Cell) = .empty;
    errdefer cells.deinit(allocator);

    var banks: [map.bank_count]map.Bank = undefined;
    var parsed: usize = 0;
    errdefer for (0..parsed) |i| banks[i].deinit(allocator);
    while (parsed < map.bank_count) : (parsed += 1) {
        banks[parsed] = try map.parseBank(allocator, rom, map.first_bank + @as(u8, @intCast(parsed)));
    }
    defer for (0..map.bank_count) |i| banks[i].deinit(allocator);

    var choice: [map.bank_count][map.cells]?Choice = @splat(@splat(null));
    var conflicts: usize = 0;
    var inheriting: usize = 0;

    var decoded = try door.decodeRegion(allocator, door.region(rom).?);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom).?;

    for (0..door.pointer_count) |di| {
        const ops = scriptOps(decoded, ptrs, di) orelse continue;
        var tt: ?u4 = null;
        var bg: ?[]const u8 = null;
        for (ops) |op| switch (op) {
            .tiletable => |v| tt = v,
            .load => |l| if (l.which == .bg) {
                bg = entryNameAt(l.src_bank, l.src_addr);
            },
            .copy => |c| if (c.which == .bg) {
                bg = entryNameAt(c.src_bank, c.src_addr);
            },
            .warp => |w| {
                if (tt) |t| {
                    seed(&choice, &conflicts, w.bank, w.pos, .{
                        .door_index = @intCast(di),
                        .tiletable = t,
                        .bg_gfx = bg,
                    });
                } else inheriting += 1;
            },
            .enter_queen => |q| {
                // No grid position of its own: the queen's entry carries a
                // world scroll, whose high bytes are the screen coordinates.
                const pos: u8 = @as(u8, @truncate(q.scroll_y >> 8)) *% 16 +% @as(u8, @truncate(q.scroll_x >> 8));
                if (tt) |t| {
                    seed(&choice, &conflicts, q.bank, pos, .{
                        .door_index = @intCast(di),
                        .tiletable = t,
                        .bg_gfx = bg,
                    });
                } else inheriting += 1;
            },
            else => {},
        };
    }

    // A warp names the cell Samus's *position* lands in, which is not always
    // the cell that gets drawn. The camera is derived from her full 12-bit
    // position -- $2939 and its three siblings subtract $74/$78 in Y and add
    // or subtract $50/$60/$80 in X -- and the door preserves her offset within
    // the screen, so the borrow or carry out of the low byte can move the drawn
    // screen by one cell in each axis, never more. That is why 50 of the 62
    // warps that state a tileset appear to target an unused cell: they name a
    // filler cell beside the room, and the room is the neighbour.
    //
    // So a warp onto a filler cell is handed to its in-use neighbour, but only
    // when there is exactly one -- with two or more, which room the door meant
    // is genuinely undecided by the ROM, and `spread` reaches them as
    // `.scrolled` instead of guessing here.
    var handed_on: usize = 0;
    for (0..map.bank_count) |bi| {
        for (0..map.cells) |ci| {
            const ch = choice[bi][ci] orelse continue;
            if (ch.provenance != .door) continue;
            if (banks[bi].cells[ci].inUse()) continue;
            var only: ?usize = null;
            var count: usize = 0;
            for (neighbours(ci)) |maybe| {
                const ni = maybe orelse continue;
                if (!banks[bi].cells[ni].inUse()) continue;
                if (choice[bi][ni] != null) continue;
                count += 1;
                only = ni;
            }
            if (count != 1) continue;
            choice[bi][only.?] = ch;
            handed_on += 1;
        }
    }

    // A door that warps without selecting a table leaves the previous room's
    // loaded, so its target's tileset is the *source* room's -- which is a fact
    // the door table does state, one hop removed. `inheriting_doors` counts
    // them and until now they seeded nothing at all.
    const before_inheriting = choice;
    var inherited = try inheritSeeds(&choice, &banks, decoded, ptrs);

    // And adopted per bank, only where the ROM says it did not make the picture
    // flatter. See `collapsedPairs` for what is being measured and why this
    // veto exists: over five of the six banks the pass is a large improvement
    // by that measure, and in bank $9 it is a regression, so the answer is not
    // to weigh them against each other but to take the pass where it helps.
    for (0..map.bank_count) |bi| {
        var with_pass = choice[bi];
        var without_pass = before_inheriting[bi];
        var ignored: usize = 0;
        try spread(&with_pass, banks[bi], &ignored);
        fillBankDefault(&with_pass, banks[bi]);
        try spread(&without_pass, banks[bi], &ignored);
        fillBankDefault(&without_pass, banks[bi]);
        if (opts.veto and collapsedPairs(rom, banks[bi], &with_pass) > collapsedPairs(rom, banks[bi], &without_pass)) {
            choice[bi] = before_inheriting[bi];
            inherited.vetoed_banks += 1;
        }
    }

    var ambiguous: usize = 0;
    for (0..map.bank_count) |bi| {
        try spread(&choice[bi], banks[bi], &ambiguous);
        fillBankDefault(&choice[bi], banks[bi]);
    }

    var in_use: usize = 0;
    var by_provenance: [@typeInfo(Provenance).@"enum".fields.len]usize = @splat(0);
    for (0..map.bank_count) |bi| {
        for (banks[bi].cells) |c| {
            if (!c.inUse()) continue;
            in_use += 1;
            if (choice[bi][c.index()]) |ch| by_provenance[@intFromEnum(ch.provenance)] += 1;
            try cells.append(allocator, .{
                .bank = banks[bi].bank,
                .x = c.x,
                .y = c.y,
                .screen_ptr = c.screen_ptr,
                .choice = choice[bi][c.index()],
            });
        }
    }

    return .{
        .cells = try cells.toOwnedSlice(allocator),
        .conflicts = conflicts,
        .in_use = in_use,
        .by_provenance = by_provenance,
        .handed_to_neighbour = handed_on,
        .inherited_seeds = inherited.seeds,
        .vetoed_banks = inherited.vetoed_banks,
        .ambiguous = ambiguous,
        .inheriting_doors = inheriting,
    };
}

/// The four orthogonal neighbours of a grid cell, or null where the grid ends.
/// The order is fixed so two runs hand a filler seed to the same neighbour.
fn neighbours(index: usize) [4]?usize {
    const y = index / map.grid_w;
    const x = index % map.grid_w;
    return .{
        if (y > 0) index - map.grid_w else null,
        if (y + 1 < map.grid_h) index + map.grid_w else null,
        if (x > 0) index - 1 else null,
        if (x + 1 < map.grid_w) index + 1 else null,
    };
}

fn seed(choice: *[map.bank_count][map.cells]?Choice, conflicts: *usize, bank: u4, pos: u8, c: Choice) void {
    if (bank < map.first_bank or bank > map.last_bank) return;
    const bi = bank - map.first_bank;
    if (choice[bi][pos]) |old| {
        if (!old.eql(c)) conflicts.* += 1;
        return;
    }
    choice[bi][pos] = c;
}

/// How many rounds of inheritance to run before giving up.
///
/// A chain of table-less doors passes the table along one hop per round.
/// **Measured on the retail ROM: 95 seeds in the first round, 98 by the second,
/// and nothing after** -- the four is headroom, and it is a cap rather than a
/// fixpoint loop because a cycle of table-less doors would otherwise never
/// settle.
const inherit_rounds: usize = 4;

/// Seed the targets of doors that never selected a table, from the room they
/// were entered from.
///
/// **This is what the game does.** `TILETABLE` loads a table; a script without
/// one leaves whatever was loaded, so walking through such a door carries the
/// source room's tileset into the target room. The door table therefore does
/// state these tilesets -- one hop removed, through the cell whose `transition`
/// word names the script.
///
/// A tentative spread runs each round so a source cell that is itself only
/// `.scrolled` can still pass its table on; the tentative answers are thrown
/// away and only the seeds are kept, so the real spread still runs once, from
/// every seed at once, in `assign`.
///
/// A door used from two rooms that disagree seeds nothing. Which table it
/// carries then genuinely depends on which way the player came, and inventing
/// an answer would be worse than the guess `spread` already makes.
fn inheritSeeds(
    choice: *[map.bank_count][map.cells]?Choice,
    banks: *const [map.bank_count]map.Bank,
    decoded: door.Decoded,
    ptrs: []const u8,
) !Inherited {
    var added: usize = 0;
    for (0..inherit_rounds) |_| {
        var tentative = choice.*;
        var ignored: usize = 0;
        for (0..map.bank_count) |bi| try spread(&tentative[bi], banks[bi], &ignored);

        var this_round: usize = 0;
        for (0..door.pointer_count) |di| {
            const ops = scriptOps(decoded, ptrs, di) orelse continue;
            var target: ?struct { bank: u4, pos: u8 } = null;
            for (ops) |op| switch (op) {
                .tiletable => {
                    target = null;
                    break;
                },
                .warp => |w| target = .{ .bank = w.bank, .pos = w.pos },
                else => {},
            };
            const t = target orelse continue;
            if (t.bank < map.first_bank or t.bank > map.last_bank) continue;

            // Every room this door is used from has to agree about what it
            // would be carrying.
            //
            // **The whole `Choice`, not just the table.** A door that names no
            // table usually loads no graphics either, so what the target room
            // inherits is the source room's *loaded state* -- and the
            // `door_index` is how the renderer finds the VRAM that state
            // implies. Seeding the table-less door's own index instead put 400
            // screens behind a script that writes no tiles: `zig build verify`
            // caught it as the metatile-quadrant fault falling from 828 screens
            // disturbed to 428, because a fault in a tile nothing draws is a
            // fault nothing can see.
            var from: ?Choice = null;
            var disagreed = false;
            for (0..map.bank_count) |bi| {
                for (0..map.cells) |ci| {
                    if (banks[bi].cells[ci].transition != di) continue;
                    const src = tentative[bi][ci] orelse continue;
                    if (from) |f| {
                        if (!f.eql(src)) disagreed = true;
                    } else from = src;
                }
            }
            if (disagreed) continue;
            const carried = from orelse continue;

            const bi = t.bank - map.first_bank;
            const seeded = seedOrHandOn(&choice[bi], banks[bi], t.pos, .{
                .door_index = carried.door_index,
                .tiletable = carried.tiletable,
                .bg_gfx = carried.bg_gfx,
                .provenance = .inherited,
                .distance = 0,
            });
            if (seeded) this_round += 1;
        }
        added += this_round;
        if (this_round == 0) break;
    }
    return .{ .seeds = added };
}

pub const Inherited = struct { seeds: usize, vetoed_banks: usize = 0 };

/// How many pairs of *different* metatile indices a bank's screens use that
/// expand to the *same* four tiles in the table each screen was assigned.
///
/// **A check on a tileset choice that needs no emulator and no reference.** A
/// screen names metatiles by index; if two indices it uses draw the same
/// picture, a distinction the screen data was making has been lost, and the
/// screen is being rendered flatter than the ROM drew it. Right tables keep
/// distinct indices distinct. It is never zero -- the ROM does reuse a picture
/// under two indices, usually for tiles that differ in collision rather than in
/// appearance -- so it is a quantity to minimise rather than a predicate.
///
/// This is what caught the first version of `inheritSeeds`, which carried the
/// table-less door's own index as the `door_index` and so drew 400 screens
/// through a script that writes no tiles.
fn collapsedPairs(rom: []const u8, bank: map.Bank, choice: *const [map.cells]?Choice) usize {
    var total: usize = 0;
    for (0..map.cells) |i| {
        if (!bank.cells[i].inUse()) continue;
        const ch = choice[i] orelse continue;
        const table = metatileTable(rom, ch.tiletable) orelse continue;
        const body = map.screenBody(rom, bank.bank, bank.cells[i].screen_ptr) orelse continue;
        var used: [256]bool = @splat(false);
        for (body) |mt| used[mt] = true;
        for (0..256) |x| {
            if (!used[x] or (x + 1) * 4 > table.len) continue;
            for (x + 1..256) |y| {
                if (!used[y] or (y + 1) * 4 > table.len) continue;
                if (std.mem.eql(u8, table[x * 4 ..][0..4], table[y * 4 ..][0..4])) total += 1;
            }
        }
    }
    return total;
}

/// Place a seed on `pos`, or on its single in-use neighbour when `pos` is a
/// filler cell. Returns whether anything was placed.
///
/// The same rule as `assign`'s hand-on pass and for the same reason -- a warp
/// names the cell Samus's position lands in, which can be one cell off the one
/// that gets drawn.
fn seedOrHandOn(choice: *[map.cells]?Choice, bank: map.Bank, pos: u8, c: Choice) bool {
    if (bank.cells[pos].inUse()) {
        if (choice[pos] != null) return false;
        choice[pos] = c;
        return true;
    }
    var only: ?usize = null;
    var count: usize = 0;
    for (neighbours(pos)) |maybe| {
        const ni = maybe orelse continue;
        if (!bank.cells[ni].inUse()) continue;
        if (choice[ni] != null) continue;
        count += 1;
        only = ni;
    }
    if (count != 1) return false;
    choice[only.?] = c;
    return true;
}

/// Breadth-first from every warp target at once, over plain grid adjacency
/// between in-use screens.
///
/// Adjacency, not the scroll flags. The flags mark where the *camera* stops,
/// which cuts the map into 239 fragments -- far finer than an area, and only 36
/// of them contain a warp target at all. Screens still share their neighbour's
/// graphics across a camera stop. Starting every seed together means each
/// screen takes the tileset of the warp target nearest it, and a screen equally
/// near two disagreeing targets is counted rather than quietly resolved.
fn spread(choice: *[map.cells]?Choice, bank: map.Bank, ambiguous: *usize) !void {
    var queue: [map.cells]u8 = undefined;
    var head: usize = 0;
    var tail: usize = 0;
    for (0..map.cells) |i| {
        if (choice[i] != null) {
            queue[tail] = @intCast(i);
            tail += 1;
        }
    }

    while (head < tail) : (head += 1) {
        const i = queue[head];
        const mine = choice[i].?;
        const x: i32 = @intCast(i % map.grid_w);
        const y: i32 = @intCast(i / map.grid_w);
        for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |d| {
            const nx = x + d[0];
            const ny = y + d[1];
            if (nx < 0 or nx >= map.grid_w or ny < 0 or ny >= map.grid_h) continue;
            const ni: usize = @intCast(ny * @as(i32, map.grid_w) + nx);
            if (!bank.cells[ni].inUse()) continue;
            if (choice[ni]) |other| {
                // Same distance from two seeds that disagree: the boundary
                // between two areas falls somewhere in here, and this rule
                // cannot say where.
                if (other.provenance != .door and other.distance == mine.distance + 1 and !other.eql(mine)) {
                    ambiguous.* += 1;
                }
                continue;
            }
            choice[ni] = .{
                .door_index = mine.door_index,
                .tiletable = mine.tiletable,
                .bg_gfx = mine.bg_gfx,
                .provenance = .scrolled,
                .distance = mine.distance +| 1,
            };
            queue[tail] = @intCast(ni);
            tail += 1;
        }
    }
}

/// Regions no warp reaches take the bank's most common tileset. Named `.bank`
/// so nothing downstream can mistake it for something the ROM said.
fn fillBankDefault(choice: *[map.cells]?Choice, bank: map.Bank) void {
    var votes: [tiletable_order.len]usize = @splat(0);
    var best: ?Choice = null;
    for (0..map.cells) |i| {
        if (choice[i]) |c| votes[c.tiletable] += 1;
    }
    var top: usize = 0;
    for (votes, 0..) |n, t| {
        if (n > top) {
            top = n;
            for (0..map.cells) |i| {
                if (choice[i]) |c| {
                    if (c.tiletable == t) {
                        best = c;
                        break;
                    }
                }
            }
        }
    }
    const fallback = best orelse return;
    for (0..map.cells) |i| {
        if (choice[i] != null or !bank.cells[i].inUse()) continue;
        choice[i] = .{
            .door_index = fallback.door_index,
            .tiletable = fallback.tiletable,
            .bg_gfx = fallback.bg_gfx,
            .provenance = .bank,
            .distance = 0,
        };
    }
}

/// The offsets entry a door operand points into. Containment rather than
/// equality, because `bg_queenHead` is copied a row at a time out of the middle
/// of one entry.
pub fn entryNameAt(bank: u8, addr: u16) ?[]const u8 {
    const src = door.resolveSource(bank, addr) orelse return null;
    return src.name;
}

/// The operation stream of script `index`, ending at its `END_DOOR`.
///
/// Scripts are not independently framed -- several pointers land partway into
/// what a linear read sees as one run -- so a script is "from this pointer to
/// the next end", which is exactly how the engine executes it.
pub fn scriptOps(decoded: door.Decoded, ptrs: []const u8, index: usize) ?[]const door.Op {
    if (index * 2 + 1 >= ptrs.len) return null;
    const addr = std.mem.readInt(u16, ptrs[index * 2 ..][0..2], .little);
    const start = decoded.indexOfAddr(addr) orelse return null;
    var i = start;
    while (i < decoded.ops.items.len) : (i += 1) {
        if (decoded.ops.items[i] == .end) return decoded.ops.items[start .. i + 1];
    }
    return decoded.ops.items[start..];
}

/// The metatile table a `TILETABLE` operand selects, as bytes.
///
/// A table is a *base* into one contiguous region, not a bounded array. The
/// three lavaCaves entries are equal-sized adjacent windows ($5480, $5594,
/// $56A8, $114 each) and lava screens index straight across them -- the
/// highest index in use is 98 against a 69-entry window. Slicing to the
/// nominal entry size would report seven perfectly ordinary screens as
/// corrupt. So the slice runs from the entry's base to the end of the region,
/// and an index past *that* is a genuine error.
///
/// **The base is the ROM's pointer, not `tiletable_order`'s name.**
/// `door_loadTiletable` (00:$282A) reads it out of `metatile_pointers`, and
/// so does this. `tiletable_order` is what the cart's `TileTableBases` are
/// built from, so every grader that expands a room through this function is
/// checking that list against the ROM rather than against itself. Until
/// 2026-09-24 it resolved through the list, and the lava slots were wrong in
/// both places at once.
pub fn metatileTable(rom: []const u8, tt: u4) ?[]const u8 {
    if (tt >= tiletable_order.len) return null;
    const ptrs = offsets.find("metatile_pointers") orelse return null;
    if (ptrs.romEnd() > rom.len) return null;
    const addr = std.mem.readInt(u16, rom[ptrs.romOffset() + @as(usize, tt) * 2 ..][0..2], .little);
    if (addr < 0x4000 or addr >= 0x8000) return null;
    const at = @as(usize, ptrs.bank) * offsets.bank_size + (addr & 0x3FFF);
    const end = metatileRegionEnd();
    if (end > rom.len or at >= end) return null;
    return rom[at..end];
}

fn metatileRegionEnd() usize {
    var end: usize = 0;
    for (offsets.entries) |e| {
        if (e.kind == .metatiles) end = @max(end, e.romEnd());
    }
    return end;
}

// ---- Rendering ------------------------------------------------------------

/// The 8 KiB of VRAM a room's door script leaves behind. Built by replaying
/// that script's copies, so a tile id that resolves to bytes nobody wrote is
/// visible as such rather than silently rendering as zeros.
pub const Vram = struct {
    bytes: [0x2000]u8 = @splat(0),
    written: [0x2000]bool = @splat(false),

    pub fn store(self: *Vram, dest: u16, src: []const u8) void {
        if (dest < 0x8000) return;
        const off: usize = dest - 0x8000;
        const n = @min(src.len, self.bytes.len - off);
        @memcpy(self.bytes[off..][0..n], src[0..n]);
        @memset(self.written[off..][0..n], true);
    }

    /// Byte offset of tile `id` under the $8800 signed addressing mode.
    pub fn tileOffset(id: u8) usize {
        const signed: i32 = @as(i8, @bitCast(id));
        return @intCast(0x9000 - 0x8000 + signed * 16);
    }

    pub fn tileWritten(self: Vram, id: u8) bool {
        const off = tileOffset(id);
        for (0..16) |i| {
            if (!self.written[off + i]) return false;
        }
        return true;
    }

    pub fn tile(self: Vram, id: u8) gfx.Tile {
        const off = tileOffset(id);
        return gfx.Tile.decode(self.bytes[off..][0..16]);
    }
};

/// Replay one door script's graphics loads into a fresh VRAM image.
pub fn vramFor(rom: []const u8, ops: []const door.Op) Vram {
    var v: Vram = .{};
    for (ops) |op| switch (op) {
        .load => |l| {
            const len: u16 = switch (l.which) {
                .bg => load_bg_len,
                .spr => load_spr_len,
            };
            const src = sliceAtLen(rom, l.src_bank, l.src_addr, len) orelse continue;
            v.store(switch (l.which) {
                .bg => load_bg_dest,
                .spr => load_spr_dest,
            }, src);
        },
        .copy => |c| {
            const src = sliceAtLen(rom, c.src_bank, c.src_addr, c.len) orelse continue;
            v.store(c.dest, src);
        },
        else => {},
    };
    return v;
}

fn sliceAtLen(rom: []const u8, bank: u8, addr: u16, len: u16) ?[]const u8 {
    const base = @as(usize, bank) * offsets.bank_size + (addr & 0x3FFF);
    if (base + len > rom.len) return null;
    return rom[base..][0..len];
}

/// Result of drawing one screen.
pub const Rendered = struct {
    /// Shade index per pixel, row-major, `screen_px` wide.
    pixels: []u8,
    /// Metatile cells whose tile id addressed VRAM nothing had written.
    unwritten_tiles: usize,
    /// Metatile indexes past the end of the assigned table.
    out_of_range: usize,

    pub fn deinit(self: *Rendered, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Draw a 256x256 screen from its metatile indexes.
///
/// Full screen, not the 160x144 play window: a screen is four times the size of
/// the window, and diffing only what fits on the Game Boy at once would leave
/// most of every room unchecked by the very test meant to prove the conversion
/// reads it correctly.
pub fn renderScreen(
    allocator: std.mem.Allocator,
    body: []const u8,
    metatiles: []const tileset.Metatile,
    vram: Vram,
    bgp: u8,
) !Rendered {
    const pixels = try allocator.alloc(u8, screen_pixels);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    var unwritten: usize = 0;
    var out_of_range: usize = 0;

    for (0..map.grid_h) |row| {
        for (0..map.grid_w) |col| {
            const mt_index = body[row * map.grid_w + col];
            if (mt_index >= metatiles.len) {
                out_of_range += 1;
                continue;
            }
            const mt = metatiles[mt_index];
            for (0..2) |qy| {
                for (0..2) |qx| {
                    const id = mt.get(@intCast(qx), @intCast(qy));
                    // `blank_tile` is the tables' "nothing here" id. It is a
                    // real VRAM tile, but only the handful of rooms that copy
                    // `gfx_commonItems` have written it, so drawing it as
                    // colour 0 keeps an unloaded blank from showing as noise.
                    const t: gfx.Tile = if (id == tileset.blank_tile)
                        .{ .pixels = @splat(@splat(0)) }
                    else blk: {
                        if (!vram.tileWritten(id)) unwritten += 1;
                        break :blk vram.tile(id);
                    };
                    const px0 = col * 16 + qx * 8;
                    const py0 = row * 16 + qy * 8;
                    for (0..8) |ty| {
                        for (0..8) |tx| {
                            pixels[(py0 + ty) * screen_px + px0 + tx] =
                                @intCast((bgp >> (@as(u3, t.pixels[ty][tx]) * 2)) & 3);
                        }
                    }
                }
            }
        }
    }

    return .{ .pixels = pixels, .unwritten_tiles = unwritten, .out_of_range = out_of_range };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the tiletable list names ten real entries" {
    try testing.expectEqual(@as(usize, 10), tiletable_order.len);
    for (tiletable_order) |n| try testing.expect(offsets.find(n) != null);
}

test "the metatile tables form one contiguous region" {
    // `metatileTable` slices from a base to the end of the region rather than
    // to the end of its own entry. That is only sound if the entries actually
    // abut, so check it here instead of trusting the address list by eye.
    var list: [16]offsets.Entry = undefined;
    var n: usize = 0;
    for (offsets.entries) |e| {
        if (e.kind == .metatiles) {
            list[n] = e;
            n += 1;
        }
    }
    try testing.expectEqual(tiletable_order.len, n);
    std.mem.sort(offsets.Entry, list[0..n], {}, struct {
        fn lt(_: void, a: offsets.Entry, b: offsets.Entry) bool {
            return a.romOffset() < b.romOffset();
        }
    }.lt);
    for (1..n) |i| try testing.expectEqual(list[i - 1].romEnd(), list[i].romOffset());

    // And the three lava windows are the equal-sized run that lets a screen
    // index across them.
    const mid = offsets.find("metatiles_lavaCavesMid").?;
    const empty = offsets.find("metatiles_lavaCavesEmpty").?;
    const full = offsets.find("metatiles_lavaCavesFull").?;
    try testing.expectEqual(mid.size, empty.size);
    try testing.expectEqual(mid.size, full.size);
    try testing.expectEqual(mid.romEnd(), empty.romOffset());
    try testing.expectEqual(empty.romEnd(), full.romOffset());
}

test "signed tile addressing puts id $F0 where gfx_commonItems is copied" {
    // The door data copies gfx_commonItems to $8F00. If ids are read through
    // the $8800 signed mode, id $F0 must land exactly there -- that agreement
    // is the whole reason the addressing mode is not a guess.
    try testing.expectEqual(@as(usize, 0x8F00 - 0x8000), Vram.tileOffset(0xF0));
    try testing.expectEqual(@as(usize, 0x9000 - 0x8000), Vram.tileOffset(0x00));
    try testing.expectEqual(@as(usize, 0x97F0 - 0x8000), Vram.tileOffset(0x7F));
    try testing.expectEqual(@as(usize, 0x8FF0 - 0x8000), Vram.tileOffset(0xFF));
}

test "tiletable indexes agree with the graphics loaded beside them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const decoded = try door.decodeRegion(arena, door.region(rom).?);
    const ptrs = door.pointers(rom).?;

    // For each TILETABLE operand, the set of BG graphics loaded in the same
    // script. A tileset's graphics and its metatile table are a pair, so a
    // slot that saw two unrelated tilesets would mean the list is wrong.
    var seen: [16]?[]const u8 = @splat(null);
    var pinned: usize = 0;
    for (0..door.pointer_count) |di| {
        const ops = scriptOps(decoded, ptrs, di) orelse continue;
        var bg: ?[]const u8 = null;
        for (ops) |op| switch (op) {
            .load => |l| if (l.which == .bg) {
                bg = entryNameAt(l.src_bank, l.src_addr);
            },
            .tiletable => |t| {
                if (bg) |g| {
                    // Compare tilesets, not graphics entries: lavaCaves has
                    // three interchangeable blobs (A, B, C) behind one
                    // metatile table, so requiring the same *file* each time
                    // would fail on data that is perfectly consistent.
                    const ts = tilesetOwning(g).?;
                    if (seen[t]) |prev| {
                        try testing.expectEqualStrings(prev, ts.name);
                    } else {
                        seen[t] = ts.name;
                        pinned += 1;
                    }
                }
            },
            else => {},
        };
    }

    // Every slot a door pinned must name a metatile table belonging to the
    // same tileset as the graphics it was loaded with.
    for (seen, 0..) |maybe_name, i| {
        const ts_name = maybe_name orelse continue;
        try testing.expect(i < tiletable_order.len);
        var owned = false;
        for (tileset.tilesets) |ts| {
            if (!std.mem.eql(u8, ts.name, ts_name)) continue;
            for (ts.metatiles) |m| {
                if (std.mem.eql(u8, m, tiletable_order[i])) owned = true;
            }
        }
        try testing.expect(owned);
    }
    // Slot 7 is the only one no door pairs with graphics in a straight read:
    // door $0D9 reaches it only through an `IF_MET_LESS` branch. The pointer
    // table pins it regardless; see the test below.
    try testing.expect(seen[7] == null);
    try testing.expectEqual(@as(usize, 9), pinned);
}

test "a TILETABLE operand selects the table the ROM's pointer table names" {
    // `door_loadTiletable` (00:$282A) doubles the operand and reads a pointer
    // at 08:$7F1A. The graphics test above cannot tell the three lava tables
    // apart, because all three go with the same graphics; this can. Until
    // 2026-09-24 slots 6-8 were layout order, Mid/Empty/Full, where the ROM
    // says Empty/Full/Mid, and every lava room drew one acid level high.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const e = offsets.find("metatile_pointers").?;
    const ptrs = rom[e.romOffset()..e.romEnd()];
    try testing.expectEqual(tiletable_order.len * 2, ptrs.len);
    for (tiletable_order, 0..) |name, operand| {
        const addr = std.mem.readInt(u16, ptrs[operand * 2 ..][0..2], .little);
        const want = offsets.find(name).?;
        try testing.expectEqual(@as(u8, 0x8), want.bank);
        try testing.expectEqual(want.gb_addr, addr);
    }
}

test "collision and solidity operands agree with the graphics loaded beside them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const decoded = try door.decodeRegion(arena, door.region(rom).?);
    const ptrs = door.pointers(rom).?;

    // For each operand value, the tileset every script that used it had loaded.
    // A second, different tileset on the same operand would mean the order is
    // wrong -- which is exactly how the layout-order reading was caught.
    var by_collision: [16]?[]const u8 = @splat(null);
    var by_solidity: [16]?[]const u8 = @splat(null);
    var collision_uses: [16]usize = @splat(0);

    for (0..door.pointer_count) |di| {
        const ops = scriptOps(decoded, ptrs, di) orelse continue;
        var bg: ?[]const u8 = null;
        for (ops) |op| switch (op) {
            .load => |l| if (l.which == .bg) {
                bg = entryNameAt(l.src_bank, l.src_addr);
            },
            .collision => |v| if (bg) |g| {
                const ts = tilesetOwning(g).?;
                if (by_collision[v]) |prev| {
                    try testing.expectEqualStrings(prev, ts.name);
                } else by_collision[v] = ts.name;
                collision_uses[v] += 1;
            },
            .solidity => |v| if (bg) |g| {
                const ts = tilesetOwning(g).?;
                if (by_solidity[v]) |prev| {
                    try testing.expectEqualStrings(prev, ts.name);
                } else by_solidity[v] = ts.name;
            },
            else => {},
        };
    }

    // Every slot is pinned, and each names the tileset `tileset_order` claims.
    for (tileset.tileset_order, 0..) |want, i| {
        const ts_name = by_collision[i] orelse return error.UnpinnedCollisionSlot;
        try testing.expectEqualStrings(want, ts_name);
        // Between 3 and 27 scripts pin each slot; none rests on a single script.
        try testing.expect(collision_uses[i] >= 3);
        // SOLIDITY indexes the same tilesets, so wherever both appear they agree.
        if (by_solidity[i]) |sol| try testing.expectEqualStrings(ts_name, sol);
    }
    // Nothing addresses a ninth tileset.
    for (tileset.tileset_order.len..16) |i| try testing.expect(by_collision[i] == null);
}

test "the solidity rows fit the metatile tables they are indexed with" {
    // Independent of the door scripts: a row's thresholds are metatile indexes,
    // so they must land inside the table the same index selects. lavaCaves is
    // the discriminating case -- 69 metatiles against everyone else's 128 --
    // and it is what makes this a check rather than a formality.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    const sol = tileset.slice(rom, "solidity_thresholds").?;
    var saw_lava = false;
    for (tileset.tileset_order, 0..) |ts_name, i| {
        // The smallest metatile table this tileset uses.
        var smallest: usize = std.math.maxInt(usize);
        for (tileset.tilesets) |ts| {
            if (!std.mem.eql(u8, ts.name, ts_name)) continue;
            for (ts.metatiles) |m| {
                const e = offsets.find(m).?;
                smallest = @min(smallest, e.size / 4);
            }
        }
        try testing.expect(smallest != std.math.maxInt(usize));
        if (smallest == 69) saw_lava = true;
        for (sol[i * 4 ..][0..3]) |threshold| {
            // A threshold is either a real metatile index inside this
            // tileset's table, or a value above *every* table in the game --
            // queen's row is $F0 across the board, which no index can reach and
            // so means "nothing here is in this class". What is not allowed is
            // the in-between: an index below $80 that still overruns the table
            // it was matched with. That is exactly what layout order produced
            // for lavaCaves (row 6, thresholds 92/84/100 against 69 metatiles),
            // and it is what this check exists to catch.
            try testing.expect(threshold <= smallest or threshold >= 128);
        }
        try testing.expectEqual(@as(u8, 0xFF), sol[i * 4 + 3]);
    }
    try testing.expect(saw_lava);
}

fn tilesetOwning(gfx_name: []const u8) ?tileset.Tileset {
    for (tileset.tilesets) |ts| {
        for (ts.gfx) |g| {
            if (std.mem.eql(u8, g, gfx_name)) return ts;
        }
    }
    return null;
}

test "every in-use screen gets a tileset, and no two doors disagree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var a = try assign(arena, rom);
    defer a.deinit(arena);

    try testing.expectEqual(@as(usize, 0), a.conflicts);
    // Every in-use screen ends up with a tileset; what varies is how much the
    // ROM said about it, which `by_provenance` records.
    var assigned: usize = 0;
    for (a.by_provenance) |n| assigned += n;
    try testing.expectEqual(a.in_use, assigned);
    try testing.expectEqual(@as(usize, 905), a.in_use);
    // Step 7 pinned the `WARP` operand: high nibble the screen row, low nibble
    // the column, both read out of the handler at bank 0 $28FB and confirmed by
    // running all 512 door scripts. That did not change how the operand is
    // read -- it was already right -- but it did explain why so few in-use
    // screens were named by one, and handing a filler-cell warp to its single
    // in-use neighbour raises the count from 13 to 41.
    //
    // Asserted rather than left implicit so that a change here is noticed
    // instead of silently improving or degrading the frames.
    try testing.expectEqual(@as(usize, 41), a.by_provenance[@intFromEnum(Provenance.door)]);
    try testing.expectEqual(@as(usize, 28), a.handed_to_neighbour);
}

test "no screen is drawn through a table that collapses the metatiles it uses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var a = try assign(arena, rom);
    defer a.deinit(arena);

    // `collapsedPairs` is the measurement `assign` itself uses to decide
    // whether to keep the inheritance pass in a bank; this is the standing
    // ceiling on the answer it arrives at.
    var total: usize = 0;
    for (0..map.bank_count) |bi| {
        const bank_no = map.first_bank + @as(u8, @intCast(bi));
        var bank = try map.parseBank(arena, rom, bank_no);
        defer bank.deinit(arena);
        var choice: [map.cells]?Choice = @splat(null);
        for (a.cells) |c| {
            if (c.bank != bank_no) continue;
            choice[@as(usize, c.y) * map.grid_w + c.x] = c.choice;
        }
        total += collapsedPairs(rom, bank, &choice);
    }

    // Measured 2026-09-05, over the three assignments this step produced:
    //
    //     no inheritance pass            2447 pairs
    //     the pass in every bank         1537 pairs
    //     the pass where it helps        1388 pairs   <- what `assign` does
    //
    // The middle row is why the pass is vetoed per bank rather than applied
    // everywhere: it is a large net improvement and still a regression inside
    // bank $9, which no published run reaches and nothing else grades.
    if (total > 1388) std.debug.print("\n{d} collapsed metatile pairs, was 1388\n", .{total});
    try testing.expect(total <= 1388);
}

test "the tables a running Game Boy showed, against the ones the assignment infers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var a = try assign(arena, rom);
    defer a.deinit(arena);

    // Every row here was **measured**, not chosen: `zig build oracle -- worlds`
    // replays both published runs on the Game Boy, reads the tilemap out of the
    // emulator at every cell either of them stays in, and names the metatile
    // table that explains it. This test is the cheap guard on that expensive
    // measurement -- it needs no emulator and no movie, so it runs in the unit
    // suite and fails the moment the inference moves.
    const Row = struct { bank: u8, cell: u8, table: u4, note: []const u8 };
    const measured = [_]Row{
        // Fixed by the inheritance pass. Before it these were table 9 -- the
        // one seed bank $C states, seven grid steps away -- and anchors 4 and 8
        // of the anchored sweep could not be booted into at all.
        .{ .bank = 0xC, .cell = 0x41, .table = 4, .note = "the shaft below the cave" },
        .{ .bank = 0xC, .cell = 0x51, .table = 4, .note = "anchored stretch 4's room" },
        .{ .bank = 0xC, .cell = 0x61, .table = 4, .note = "the shaft" },
        .{ .bank = 0xC, .cell = 0x71, .table = 4, .note = "anchored stretch 8's room" },
        .{ .bank = 0xC, .cell = 0x81, .table = 4, .note = "the shaft's foot" },
        .{ .bank = 0xF, .cell = 0x6A, .table = 4, .note = "the descent from the surface" },
        // Already right before the pass, and still right after it. Included
        // because the pass had to be shown not to break what worked: it seeds
        // 98 cells, and any of these turning could not otherwise be told apart
        // from the six above turning.
        .{ .bank = 0xF, .cell = 0x76, .table = 5, .note = "the landing site" },
        .{ .bank = 0xA, .cell = 0x44, .table = 4, .note = "the first cave" },
        .{ .bank = 0xA, .cell = 0x48, .table = 4, .note = "five cells further in" },
        .{ .bank = 0xF, .cell = 0x05, .table = 4, .note = "the one a door states outright" },
    };
    for (measured) |m| {
        const c = a.find(m.bank, @intCast(m.cell & 0x0F), @intCast(m.cell >> 4)) orelse {
            std.debug.print("bank ${X} cell ${X:0>2} ({s}) is not in use\n", .{ m.bank, m.cell, m.note });
            return error.TestUnexpectedResult;
        };
        const ch = c.choice orelse {
            std.debug.print("bank ${X} cell ${X:0>2} ({s}) has no tileset\n", .{ m.bank, m.cell, m.note });
            return error.TestUnexpectedResult;
        };
        if (ch.tiletable != m.table) {
            std.debug.print("bank ${X} cell ${X:0>2} ({s}): the Game Boy showed table {d}, the assignment says {d} ({s})\n", .{
                m.bank, m.cell, m.note, m.table, ch.tiletable, ch.provenance.label(),
            });
            return error.TestUnexpectedResult;
        }
    }

    // And the cells the measurement says are still wrong, recorded as wrong.
    //
    // Not aspiration: these are what `oracle -- worlds` reports as
    // disagreements today, and pinning them means a change that fixes one is
    // noticed rather than absorbed. Map 2's is the reason anchors 11 and 12
    // remain ungradable -- the Game Boy showed table 6 on all 399 compared
    // tiles and **no door in bank $B states table 6 at all**, so no inference
    // over the door table can reach it.
    //
    // **1.0 Step 18c: these are the static reading's, and only its.** The
    // port boots a cell through `warp.assignWalked`, which lays the door
    // crawl's arrivals over this and has all nine of B12's right; `warp.zig`'s
    // test of the same name holds it to them. The lava rows were table 6 here
    // until then, from before the lava slots were put in the ROM's order: the
    // Game Boy shows 8 in all three.
    const known_wrong = [_]Row{
        .{ .bank = 0xB, .cell = 0x0D, .table = 8, .note = "anchors 11 and 12" },
        .{ .bank = 0xB, .cell = 0x0E, .table = 8, .note = "next door to it" },
        .{ .bank = 0xA, .cell = 0x00, .table = 8, .note = "zero tiles agree" },
        .{ .bank = 0xF, .cell = 0x6B, .table = 4, .note = "assigned 9" },
        .{ .bank = 0xC, .cell = 0x21, .table = 4, .note = "assigned 5" },
    };
    for (known_wrong) |m| {
        const c = a.find(m.bank, @intCast(m.cell & 0x0F), @intCast(m.cell >> 4)).?;
        const ch = c.choice.?;
        if (ch.tiletable == m.table) {
            std.debug.print("bank ${X} cell ${X:0>2} ({s}) now agrees with the Game Boy at table {d};\n" ++
                "  re-run `zig build oracle -- worlds` and move this row up\n", .{ m.bank, m.cell, m.note, m.table });
            return error.TestUnexpectedResult;
        }
    }
}

test "the table-less doors carry a tileset, and dropping the pass loses it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var a = try assign(arena, rom);
    defer a.deinit(arena);

    // The pass exists because 79 in-use cells take their table from a door that
    // named none. Asserted as a count so removing the pass fails here as well
    // as in the measured-table test above -- that one would report a wrong
    // table, this one reports that nothing was carried at all.
    //
    // 79 and not 98: the seeds in banks $9 and $A are vetoed, because in those
    // two the pass made the bank's screens flatter by `collapsedPairs` -- from
    // 0 collapsed pairs to 49 and to 100. Bank $A is one the published runs do
    // reach, and `zig build oracle -- worlds` grades those cells identically
    // either way, so the proxy is deciding a case the direct measurement has no
    // opinion on rather than overruling it.
    try testing.expectEqual(@as(usize, 79), a.by_provenance[@intFromEnum(Provenance.inherited)]);
    // And what it took off the guessing: the bank default is the provenance
    // with nothing behind it, and it fell from 25 cells to 20.
    try testing.expectEqual(@as(usize, 20), a.by_provenance[@intFromEnum(Provenance.bank)]);
    try testing.expect(a.inherited_seeds > 0);
    try testing.expectEqual(@as(usize, 2), a.vetoed_banks);
}

test "every metatile index a screen uses exists in the table it was assigned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var a = try assign(arena, rom);
    defer a.deinit(arena);

    for (a.cells) |c| {
        const ch = c.choice orelse continue;
        const mts = try tileset.parseMetatiles(arena, metatileTable(rom, ch.tiletable).?);
        const body = map.screenBody(rom, c.bank, c.screen_ptr) orelse continue;
        for (body) |mt| try testing.expect(mt < mts.len);
    }
}


// ---- Rendering every screen ------------------------------------------------

/// The background palette a live room runs with.
///
/// Derived twice, because the coverage report had this class down as unread on
/// the grounds that palettes are "written by code, not stored as a table":
///
///  * Statically. There are only five `LDH` writes to a palette register in the
///    whole ROM, and none of them carries an immediate. Three are a VBlank copy
///    at 0:$0163 out of three shadow bytes -- $D07E to BGP, $D07F to OBP0,
///    $D080 to OBP1. Every immediate the ROM ever stores into those shadows:
///    BGP $93 (six sites) and $90 (one), OBP0 $93, OBP1 $43. Fades write a ramp
///    through the same shadows rather than immediates, which is Step 12's
///    problem and not a frame's.
///  * By running the game. `zig build probe -- doors` executes all 512 door
///    scripts on a booted machine and reports the palette each leaves behind:
///    274 of the 369 that load a screen leave $93. The other 95 leave $FF, a
///    fully dark palette from a fade that had not yet reversed when the script
///    returned.
///
/// Shade indexes, not colours. The DMG has no colours; which greens a viewer
/// shows is `png.dmg_palette`'s business and nothing compares against it.
pub const live_bgp: u8 = 0x93;

/// And the two object palettes the same survey found: `OBP0 $93`, `OBP1 $43`.
/// Same shade indexes, same caveat. OBP1 is the one `drawSamusSprite` switches
/// every part to while Samus is in acid or invulnerable, which is why it is
/// loaded in Phase 0a even though nothing here can damage her yet - a palette
/// that was never written would make the damage flash black.
pub const live_obp0: u8 = 0x93;
pub const live_obp1: u8 = 0x43;


/// Somewhere for each rendered frame to go. Same shape as `bus.Video`: a plain
/// function pointer, so the gate can render every screen and check that it is
/// reproducible without linking a PNG writer, and `zig build frames` can write
/// the images through the same loop rather than a second copy of it.
pub const FrameSink = struct {
    ctx: *anyopaque,
    frame: *const fn (ctx: *anyopaque, cell: Cell, choice: Choice, pixels: []const u8) anyerror!void,
};

pub const FrameStats = struct {
    rendered: usize = 0,
    /// Frames whose two renders of the same inputs differed. Any nonzero value
    /// means the renderer is not a function of the ROM, which would make every
    /// Step 9 diff meaningless.
    unstable: usize = 0,
    /// In-use cells whose pointer does not address a screen body. There is
    /// exactly one, the null in bank $A.
    no_body: usize = 0,
    no_choice: usize = 0,
    out_of_range: usize = 0,
    /// Quarter-metatiles drawn from a VRAM tile no door script wrote. A screen
    /// renders through the VRAM of the door that named it, and a door does not
    /// always load every tile the screens downstream of it use.
    unwritten_tiles: usize = 0,
    screens_with_unwritten: usize = 0,
    by_provenance: [@typeInfo(Provenance).@"enum".fields.len]usize = @splat(0),
    /// SHA-256 over every frame's pixels, in cell order. One number that two
    /// runs can be compared on.
    digest: [32]u8 = @splat(0),
};

/// Render every in-use screen, twice each, and hand the frames to `sink`.
pub fn renderAll(
    allocator: std.mem.Allocator,
    rom: []const u8,
    bgp: u8,
    sink: ?FrameSink,
) !FrameStats {
    var stats: FrameStats = .{};

    var assignment = try assign(allocator, rom);
    defer assignment.deinit(allocator);

    var decoded = try door.decodeRegion(allocator, door.region(rom).?);
    defer decoded.deinit(allocator);
    const ptrs = door.pointers(rom).?;

    // Ten metatile tables serve 905 screens, so they are parsed once.
    var tables: [16]?[]const tileset.Metatile = @splat(null);
    defer for (tables) |t| {
        if (t) |mts| allocator.free(mts);
    };

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (assignment.cells) |cell| {
        const choice = cell.choice orelse {
            stats.no_choice += 1;
            continue;
        };
        const body = map.screenBody(rom, cell.bank, cell.screen_ptr) orelse {
            stats.no_body += 1;
            continue;
        };
        if (tables[choice.tiletable] == null) {
            const raw = metatileTable(rom, choice.tiletable) orelse return Error.BadTiletable;
            tables[choice.tiletable] = try tileset.parseMetatiles(allocator, raw);
        }
        const metatiles = tables[choice.tiletable].?;

        const ops = scriptOps(decoded, ptrs, choice.door_index) orelse &[_]door.Op{};
        const vram = vramFor(rom, ops);

        var first = try renderScreen(allocator, body, metatiles, vram, bgp);
        defer first.deinit(allocator);
        var second = try renderScreen(allocator, body, metatiles, vram, bgp);
        defer second.deinit(allocator);
        if (!std.mem.eql(u8, first.pixels, second.pixels)) stats.unstable += 1;

        stats.rendered += 1;
        stats.out_of_range += first.out_of_range;
        stats.unwritten_tiles += first.unwritten_tiles;
        if (first.unwritten_tiles != 0) stats.screens_with_unwritten += 1;
        stats.by_provenance[@intFromEnum(choice.provenance)] += 1;
        hasher.update(first.pixels);

        if (sink) |s| try s.frame(s.ctx, cell, choice, first.pixels);
    }

    hasher.final(&stats.digest);
    return stats;
}

// ---- The warp operand, re-derived from the ROM on every run ----------------

/// Bank 0 addresses read out of the retail ROM with `zig build disasm`.
/// Recorded as constants so the test below fails loudly if a different ROM is
/// configured, rather than quietly asserting nothing.
const warp_handler: u16 = 0x28FB;
const screen_index_builder: u16 = 0x0835;
const map_bank_var: u16 = 0xD058;
const screen_row_var: u16 = 0xFFC9;
const screen_col_var: u16 = 0xFFCB;
const camera_row_var: u16 = 0xFFCD;
const camera_col_var: u16 = 0xFFCF;

test "the ROM's own warp handler splits the operand into a screen row and column" {
    // `assign` reads a `WARP` operand as a 16x16 grid cell: high nibble the
    // row, low nibble the column, cell index `row * 16 + col`. That reading
    // was doubted during Step 7 because most warp targets land on cells whose
    // screen pointer is the shared $4500 body -- but that turns out to be a
    // fact about $4500, not about the operand.
    //
    // So the reading is derived here from the handler's own instructions
    // instead of being asserted. The handler is decoded with our SM83
    // disassembler and its stores are followed symbolically; nothing in this
    // test knows what the answer is supposed to be until it reads it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    // What the accumulator is known to hold. The handler is straight-line up
    // to its first call, so one abstract value is enough.
    const Held = enum { unknown, opcode, opcode_low, operand, operand_high, operand_low };
    var a: Held = .unknown;
    // HL walks the script: the opcode byte first, then the operand.
    var at_operand = false;

    var row_stores: usize = 0;
    var col_stores: usize = 0;
    var bank_stores: usize = 0;
    var bank_addr: ?u16 = null;
    var row_addr: ?u16 = null;
    var col_addr: ?u16 = null;

    var pc: u16 = warp_handler;
    while (pc < warp_handler + 0x20) {
        const insn = disasm.decode(rom[pc..], pc);
        switch (insn.opcode) {
            0x2A, 0x7E => { // LD A,(HL+) / LD A,(HL)
                a = if (at_operand) .operand else .opcode;
                if (insn.opcode == 0x2A) at_operand = true;
            },
            0xE6 => { // AND d8
                if (rom[pc + 1] != 0x0F) return error.UnexpectedMask;
                a = switch (a) {
                    .opcode => .opcode_low,
                    .operand => .operand_low,
                    // SWAP then AND $0F is how the high nibble is isolated.
                    .operand_high => .operand_high,
                    else => .unknown,
                };
            },
            0xCB => { // SWAP A is the only $CB form the handler uses
                if (rom[pc + 1] != 0x37) return error.UnexpectedPrefixOp;
                a = switch (a) {
                    .operand => .operand_high,
                    else => .unknown,
                };
            },
            0xE0, 0xEA => { // LDH (a8),A / LD (a16),A
                const dest = insn.mem.?.addr;
                switch (a) {
                    .opcode_low => {
                        bank_stores += 1;
                        if (dest == map_bank_var) bank_addr = dest;
                    },
                    .operand_high => {
                        row_stores += 1;
                        if (dest == screen_row_var) row_addr = dest;
                    },
                    .operand_low => {
                        col_stores += 1;
                        if (dest == screen_col_var) col_addr = dest;
                    },
                    else => return error.UnexpectedStore,
                }
            },
            0xE5 => break, // PUSH HL: the operand has been consumed
            else => return error.UnexpectedInstruction,
        }
        pc += insn.len;
    }

    // The opcode's own low nibble is the map bank, and it is what gets written
    // to $2100 later to map it. Like the row and the column, it is stored
    // twice -- once live, once into the block the save record is built from.
    try testing.expectEqual(@as(?u16, map_bank_var), bank_addr);
    try testing.expectEqual(@as(usize, 2), bank_stores);
    // The operand's high nibble goes to the screen row, its low nibble to the
    // screen column -- each to a pair of addresses, one for Samus and one for
    // the camera the frame is drawn from.
    try testing.expectEqual(@as(?u16, screen_row_var), row_addr);
    try testing.expectEqual(@as(?u16, screen_col_var), col_addr);
    try testing.expectEqual(@as(usize, 2), row_stores);
    try testing.expectEqual(@as(usize, 2), col_stores);
}

test "the ROM builds a screen index as row * 16 + col and indexes the map bank with it" {
    // The other half of the derivation: `$0835` turns the row and column into
    // the index that reads the map bank's screen-pointer table. `SWAP` on the
    // row is a multiply by 16, `OR` with the column adds it, and the table it
    // indexes is at $4000 -- which is `map{X}_screen_pointers` in offsets.zig.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var read_row = false;
    var read_col = false;
    var swapped = false;
    var ored = false;
    var table: ?u16 = null;

    var pc: u16 = screen_index_builder;
    while (pc < screen_index_builder + 0x1A) {
        const insn = disasm.decode(rom[pc..], pc);
        if (insn.mem) |m| {
            if (m.addr == camera_row_var and !m.write) read_row = true;
            if (m.addr == camera_col_var and !m.write) read_col = true;
        }
        switch (insn.opcode) {
            0xCB => if (rom[pc + 1] == 0x37) {
                swapped = true;
            },
            0xB0 => ored = true, // OR B
            0x21 => table = @as(u16, rom[pc + 1]) | (@as(u16, rom[pc + 2]) << 8),
            else => {},
        }
        pc += insn.len;
    }

    try testing.expect(read_row);
    try testing.expect(read_col);
    try testing.expect(swapped); // row * 16
    try testing.expect(ored); // + col
    try testing.expectEqual(@as(?u16, map.ptrs_addr), table);
}
