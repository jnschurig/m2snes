//! 1.0 Step 5c (C8c): the WARP page graded. Every entry is warped to on the
//! `--debug` cart through the menu's own input, and what it arrives with is
//! held against our Game Boy running the same chain.
//!
//! **The reference** is the Game Boy's: from the new game, each script of the
//! entry's chain is run by setting the door index and calling the interpreter
//! (00:$239C), which is what `loadDoorIndex` (00:$0C37) leaves for the main
//! loop and how the original's own debug warp reached the Queen. What it left
//! is read back:
//! - the loaded state a save keeps, `$D808`-`$D814`: the enemy and background
//!   graphics' sources, the metatile and collision tables, the map bank and
//!   the solidity thresholds;
//! - the damage `DAMAGE` writes (`$D077`, `$D078`);
//! - the background's characters, the signed window `$8800`-`$97FF` in the
//!   order BG3 holds them (ids $00-$7F from `$9000`, then $80-$FF from
//!   `$8800`), since SNES 2bpp is the Game Boy's own format.
//!
//! The warp table's chains were chosen so that running them leaves what the
//! crawl's Game Boy left (`warp.build`), so this is not the same claim twice:
//! that was the tables' pointers against the crawl's walk, and this is the
//! cart's interpreter, loader and VRAM against the Game Boy's.
//!
//! **The cart** boots the debug build into a new game, and for each entry opens
//! the menu with its chord, walks the tree to the entry's row and presses A.
//! A second after she arrives it reads the same three things, and for the
//! second after that she must stand: in the pose the entry names, and neither
//! falling nor moved. The entries are split across runs that go in parallel,
//! each with its own exit codes (`code`), as the scenarios are.

const std = @import("std");
const warp = @import("warp.zig");
const room = @import("room.zig");
const harness = @import("gb/harness.zig");
const debug_tables = @import("debug_tables.zig");
const inject = @import("snes_inject.zig");
const screen = @import("snes_screen.zig");
const screens = @import("screens.zig");
const offsets = @import("offsets.zig");
const convert = @import("snes_convert.zig");

// ---- The Game Boy's side ----------------------------------------------------

/// `$D808`-`$D814`, as the cart's `!SaveBuf+$08` holds it.
pub const block_addr: u16 = 0xD808;
pub const block_len: usize = warp.block_len;
/// `$D811` within it.
const bank_at: usize = 9;
/// `metroidCountReal`, which `IF_MET_LESS` reads (00:$254A), and the count
/// the status bar shows.
const count_real_addr: u16 = 0xD089;
const count_shown_addr: u16 = 0xD09A;
/// `acidDamageValue` and `spikeDamageValue`.
pub const acid_addr: u16 = 0xD077;
pub const spike_addr: u16 = 0xD078;
/// The background's characters, in BG3's order.
pub const chars_len: usize = 0x1000;
const signed_base: u16 = 0x9000;
const window_lo: u16 = 0x8800;

pub const Ref = struct {
    block: [block_len]u8,
    acid: u8,
    spike: u8,
    chars: [chars_len]u8,
    /// The characters the loaded metatile table draws: what is graded. The
    /// rest of the window is the objects' on the Game Boy ($8800-$8AFF, ids
    /// $80-$AF, which only the Queen's table draws), and the cart keeps
    /// those in the object region alone.
    drawn: [256]bool,
    /// 1.0 Step 18a: the background map over the camera's view, `view_rows`
    /// by `view_cols` tiles from the scroll's, each cell the view touches
    /// drawn whole under what the chain left (`room.drawRoom`). What a
    /// scroll draws is that cell's own tiles at every slot it owns, and the
    /// map is one cell wide, so a slot's tile is its cell's at the same slot.
    /// Not taken for her room, whose raster split the `queen` scenario grades.
    view: [view_rows * view_cols]u8,
};

/// The Game Boy's view is 160 by 144 pixels, plus the tile each edge cuts:
/// the terrain `enemy_oracle.viewDiffers` grades, and what the play window
/// shows.
pub const view_rows: usize = 144 / 8 + 1;
pub const view_cols: usize = 160 / 8 + 1;

/// `scrollY` and `scrollX` for a camera: `camera_pixel - $48` and `- $50`,
/// 00:$2366 (and `!GB_SCROLL_Y_BIAS`/`!GB_SCROLL_X_BIAS`), whole world
/// positions.
pub fn viewOrigin(cam_y: u16, cam_x: u16) struct { u16, u16 } {
    return .{ (cam_y -% 0x48) & 0x0FFF, (cam_x -% 0x50) & 0x0FFF };
}

/// The map slot of view tile `(r, c)`: what `viewDiffers` indexes.
pub fn viewSlot(top: u16, left: u16, r: usize, c: usize) usize {
    const ty = ((top >> 3) + r) & 31;
    const tx = ((left >> 3) + c) & 31;
    return ty * 32 + tx;
}

/// The Game Boy's view for an entry: each cell it touches drawn in turn, and
/// the slots that cell owns taken from it.
fn readView(m: *harness.Machine, e: warp.Entry, out: *[view_rows * view_cols]u8) !void {
    const top, const left = viewOrigin(e.cam_y, e.cam_x);
    const S = struct {
        fn cellAt(t: u16, l: u16, r: usize, c: usize) u8 {
            const wy = (t + @as(u16, @intCast(r * 8))) & 0x0FFF;
            const wx = (l + @as(u16, @intCast(c * 8))) & 0x0FFF;
            return @truncate((wy >> 4 & 0xF0) | (wx >> 8 & 0x0F));
        }
    };
    var cells: [4]u8 = undefined;
    var nc: usize = 0;
    for (0..view_rows) |r| for (0..view_cols) |c| {
        const cell = S.cellAt(top, left, r, c);
        for (cells[0..nc]) |x| {
            if (x == cell) break;
        } else {
            cells[nc] = cell;
            nc += 1;
        }
    };
    for (cells[0..nc]) |cell| {
        room.drawRoom(m, e.dest.at.bank, @truncate(cell >> 4), @truncate(cell & 0x0F), 4_000_000) catch return Error.ChainDidNotRun;
        for (0..view_rows) |r| for (0..view_cols) |c| {
            if (S.cellAt(top, left, r, c) != cell) continue;
            out[r * view_cols + c] = m.read(room_map + @as(u16, @intCast(viewSlot(top, left, r, c))));
        };
    }
}

/// The background map the room is drawn into.
const room_map: u16 = 0x9800;

/// The ids a metatile table draws, from the ROM.
pub fn drawnBy(rom: []const u8, tiletable: u4) ?[256]bool {
    if (tiletable >= screens.tiletable_order.len) return null;
    const e = offsets.find(screens.tiletable_order[tiletable]) orelse return null;
    var d: [256]bool = @splat(false);
    for (rom[e.romOffset()..e.romEnd()]) |id| d[id] = true;
    return d;
}

/// A door script the interpreter did not finish within its budget.
pub const Error = error{ ChainDidNotRun, NoSymbol };

/// The Game Boy's reference for each entry, in the order given, warped to
/// one after another from the new game within each of the cart's runs
/// (`shardRange`), as the cart warps to them. The order matters: what a chain
/// does not load -- the enemy page (`$D808`), the damage, the characters of
/// the object window -- is what the warp before it left.
///
/// `at_count`: each chain runs at its entry's Metroid count, both counts set
/// before it (the `counts` rung, 1.0 Step 18d). The reference side may be set
/// up; the cart reaches the count from the METROIDS page.
/// Frames after she arrives the view is read (1.0 Step 19c): the map stream
/// writes one direction a frame, round-robin on the frame counter, so in four
/// every direction owed at the warp has had its frame, whatever the phase.
const stream_frames: usize = 4;

pub fn references(a: std.mem.Allocator, rom: []const u8, entries: []const warp.Entry, shards: usize, at_count: bool) ![]Ref {
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{}); // the appearance, as the crawl's new game
    var base = try m.snapshot();
    defer base.deinit(a);
    const out = try a.alloc(Ref, entries.len);
    for (entries, out, 0..) |e, *r, n| {
        if (shardStart(entries.len, n, shards)) m.restore(base);
        if (at_count) {
            m.write(count_real_addr, e.count);
            m.write(count_shown_addr, e.count);
        }
        for (e.chain[0..e.n]) |di| room.loadRoom(&m, di, 4_000_000) catch return Error.ChainDidNotRun;
        for (&r.block, 0..) |*b, i| b.* = m.read(block_addr + @as(u16, @intCast(i)));
        // The map bank is the entry's. A chain's loader can warp to another
        // bank than its door (`$003`, which loads ruinsInside, warps to bank
        // E), and a door that loads only an enemy page has no `WARP` of its
        // own: a player crossing it stays in the bank she was in.
        r.block[bank_at] = e.dest.at.bank;
        r.acid = m.read(acid_addr);
        r.spike = m.read(spike_addr);
        const t = warp.tilesetOfBlock(rom, r.block) orelse return Error.ChainDidNotRun;
        r.drawn = drawnBy(rom, t.tiletable) orelse return Error.ChainDidNotRun;
        for (0..chars_len) |i| {
            const at: u16 = if (i < 0x800) signed_base + @as(u16, @intCast(i)) else window_lo + @as(u16, @intCast(i - 0x800));
            r.chars[i] = m.read(at);
        }
        if (e.dest.kind != .queen) try readView(&m, e, &r.view);
    }
    return out;
}

// ---- 1.0 Step 18c: the tileset each cell is drawn with -----------------------

/// What `cellsDrawn` found.
pub const Drawn = struct {
    /// Cells of rooms the crawl's arrivals settle (`warp.walkedArrivals`).
    cells: usize = 0,
    /// Of those, cells whose assigned graphics or table draw differently from
    /// what our Game Boy drew under the arrival's.
    differ: usize = 0,
    /// Rooms whose arrival no one script loads from the new game.
    unloadable: usize = 0,
};

/// Every cell of every room the crawl's arrivals settle, drawn on our Game
/// Boy under what the arrival loaded (`room.drawRoom`, the loader of that
/// tileset run from the new game), against the cell expanded through `asg`'s
/// table with `asg`'s graphics: what the port boots the cell with.
pub fn cellsDrawn(a: std.mem.Allocator, rom: []const u8, asg: screens.Assignment, walked: []const warp.WalkedDoor) !Drawn {
    const door = @import("door.zig");
    const roster = @import("roster.zig");
    const map = @import("map.zig");
    var w = try roster.world(a, rom);
    defer w.deinit(a);
    var decoded = try door.decodeRegion(a, door.region(rom).?);
    defer decoded.deinit(a);
    const ptrs = door.pointers(rom).?;
    const s0 = try warp.initialState(rom, decoded);
    const arrivals = try warp.walkedArrivals(a, rom, walked);
    defer a.free(arrivals);

    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{});
    var base = try m.snapshot();
    defer base.deinit(a);

    var out: Drawn = .{};
    for (arrivals, 0..) |maybe, r| {
        const arr = maybe orelse continue;
        const t = arr.tileset orelse continue;
        // Two rooms, five cells, are arrived in with lavaCavesFull, which no
        // one script loads at the new game's count: `assignWalked` leaves
        // them to the static reading, and they are counted apart.
        const loader = warp.drawingLoader(decoded, ptrs, warp.thresholds(rom), s0, t) orelse {
            out.unloadable += 1;
            continue;
        };
        m.restore(base);
        room.loadRoom(&m, loader, 4_000_000) catch return Error.ChainDidNotRun;
        var block: [block_len]u8 = undefined;
        for (&block, 0..) |*b, i| b.* = m.read(block_addr + @as(u16, @intCast(i)));
        const got = warp.tilesetOfBlock(rom, block) orelse return Error.ChainDidNotRun;
        if (!got.bg.eql(t.bg) or got.tiletable != t.tiletable) {
            std.debug.print("cellsDrawn: room {d}'s loader ${X} left table {d} bg {X}:{X}, the arrival {d} bg {X}:{X}\n", .{ r, loader, got.tiletable, got.bg.bank, got.bg.addr, t.tiletable, t.bg.bank, t.bg.addr });
            return Error.ChainDidNotRun;
        }
        const bg_name = screens.entryNameAt(t.bg.bank, t.bg.addr) orelse "";

        for (0..map.bank_count) |bi| for (0..map.cells) |ci| {
            if (w.room[bi][ci] != r) continue;
            const bank: u8 = map.first_bank + @as(u8, @intCast(bi));
            const cell = w.banks[bi].cells[ci];
            out.cells += 1;
            room.drawRoom(&m, bank, cell.y, cell.x, 4_000_000) catch return Error.ChainDidNotRun;
            const ch = (asg.find(bank, cell.x, cell.y) orelse {
                out.differ += 1;
                continue;
            }).choice orelse {
                out.differ += 1;
                continue;
            };
            const body = warp.body(rom, w, .{ .bank = bank, .cell = @intCast(ci) }) orelse return Error.ChainDidNotRun;
            const table = screens.metatileTable(rom, ch.tiletable) orelse return Error.ChainDidNotRun;
            var same = std.mem.eql(u8, ch.bg_gfx orelse "", bg_name);
            for (0..32) |row| for (0..32) |col| {
                const mt = body[(row / 2) * 16 + col / 2];
                const want = table[@as(usize, mt) * 4 + (row % 2) * 2 + col % 2];
                if (m.read(room_map + @as(u16, @intCast(row * 32 + col))) != want) same = false;
            };
            if (!same) out.differ += 1;
        };
    }
    return out;
}

// ---- The cart's side ---------------------------------------------------------

/// The runs the entries are split across, contiguous in `warp_data`'s order.
pub const shard_count: usize = 8;

pub fn shardRange(n: usize, k: usize) struct { usize, usize } {
    return shardRangeOf(n, k, shard_count);
}

pub fn shardRangeOf(n: usize, k: usize, shards: usize) struct { usize, usize } {
    return .{ n * k / shards, n * (k + 1) / shards };
}

fn shardStart(n: usize, i: usize, shards: usize) bool {
    for (0..shards) |k| if (shardRangeOf(n, k, shards)[0] == i) return true;
    return false;
}

/// Exit codes, the same for every run.
pub fn code(c: u8) []const u8 {
    return switch (c) {
        0 => "every entry arrived as the Game Boy's, standing",
        1 => "Fatal ran",
        2 => "the new game or play never arrived, or the run outlasted its frames",
        3 => "A on the entry's row did not warp: the menu is still up",
        4 => "the engine was handed a pose it could not run",
        20 => "the warp arrived in another bank, or drew another cell than the camera's, or took another cell's scroll flags",
        26 => "the background map over the camera's view is not the Game Boy's",
        21 => "the loaded state ($D808-$D814) is not the Game Boy's after the chain",
        22 => "the damage values are not the Game Boy's after the chain",
        23 => "the background's characters are not the Game Boy's after the chain",
        24 => "she is not where the entry puts her, or not in its pose",
        25 => "she fell or moved in the second after arriving",
        27 => "the METROIDS page did not leave the entry's Metroid count",
        255 => "the emulator did not exit normally",
        else => "an unknown code: a timeout, or a script error, reads as one",
    };
}

/// Frames apart the presses are, each held for two.
const apart = 4;
/// Frames after arriving that the loaded state is read, and that she must
/// then stand for.
const settle = 10;
const stand = 60;
/// The WARP row on the menu's root.
const warp_row = 4;
/// `!POSE_HURT` and `!POSE_MORPHHURT`: an enemy's hit, not the spot.
const pose_hurt: u8 = 0x0F;
const pose_morph_hurt: u8 = 0x10;
/// Frames she must have stood before a hit ends the check. She is checked
/// stood at the spot on the frame she arrives, and a spot with no floor
/// falls on the next; a hit on that same frame (one save station's, $F:$04)
/// knocks her back instead, and is counted, not failed.
const hit_after = 0;

pub fn sym(name: []const u8) !u32 {
    return (inject.symbol(name) orelse return Error.NoSymbol) & 0x1FFFF;
}

/// FNV-1a over one character's sixteen bytes: what the script compares a
/// character by, and prints the index of when one differs.
pub fn charHash(b: []const u8) u32 {
    var h: u32 = 2166136261;
    for (b) |x| h = (h ^ x) *% 16777619;
    return h;
}

/// The presses a warp to entry `i` takes from play: the chord, Down to WARP
/// and A, Down to its list and A, the shorter way round to its row, and A.
fn pressCount(counts: [debug_tables.warp_lists.len]usize, li: usize, row: usize) usize {
    const n = counts[li];
    return 1 + warp_row + 1 + li + 1 + @min(row, n - row) + 1;
}

pub fn writeLua(a: std.mem.Allocator, rom: []const u8, sorted: []const warp.Entry, refs: []const Ref, shard: usize, shards: usize, w: *std.Io.Writer) !void {
    const lo, const hi = shardRangeOf(sorted.len, shard, shards);
    const roster = @import("roster.zig");
    var world = try roster.world(a, rom);
    defer world.deinit(a);
    var counts: [debug_tables.warp_lists.len]usize = @splat(0);
    for (sorted, 0..) |_, i| counts[debug_tables.warpRow(sorted, i)[0]] += 1;
    counts[debug_tables.ending_list] += 1; // ENDING, the QUEEN list's last row

    // The characters, one image per distinct set, as per-character hashes.
    // A character the table does not draw is -1, and not compared.
    var images: std.ArrayList([256]i64) = .empty;
    const img_of = try a.alloc(usize, hi - lo);
    for (refs[lo..hi], img_of) |r, *o| {
        var im: [256]i64 = undefined;
        for (&im, 0..) |*h, c| h.* = if (r.drawn[c]) charHash(r.chars[c * 16 ..][0..16]) else -1;
        o.* = for (images.items, 0..) |x, k| {
            if (std.mem.eql(i64, &x, &im)) break k;
        } else blk: {
            try images.append(a, im);
            break :blk images.items.len - 1;
        };
    }

    var limit: usize = 3000;
    for (lo..hi) |i| {
        const li, const row = debug_tables.warpRow(sorted, i);
        limit += pressCount(counts, li, row) * apart + 120 + stand + 2;
    }
    // The kills a `counts` run makes from the METROIDS page (1.0 Step 18d):
    // one press a row, the way to its first row, and the page each time.
    // Rows switched both ways (1.0 Step 18f): the sum of the steps between
    // one entry's count and the next.
    const mets = try debug_tables.metroidsBlob(a, rom);
    var switched: usize = 0;
    var was: usize = fromBcd(warp.start_count);
    for (sorted[lo..hi]) |e| {
        const c: usize = fromBcd(e.count);
        switched += if (c > was) c - was else was - c;
        was = c;
    }
    limit += (2 * switched + mets[0] + 8 * (hi - lo)) * apart;

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The WARP page, 1.0 Step 5c: entries {d} to {d} of {d}, warped to on the
        \\-- `--debug` cart through the menu's own input, each held against our
        \\-- Game Boy running the entry's chain (`src/warp_grade.zig`): the loaded
        \\-- state a save keeps, the damage, and the background's characters. Then
        \\-- she must stand a second where the entry puts her.
        \\--
        \\-- Exit codes: 0 every entry held; 1 Fatal; 2 no play, or out of frames;
        \\-- 3 A did not warp; 4 an unrunnable pose; 20 another bank or cell; 21 the
        \\-- loaded state; 22 the damage; 23 the characters; 24 not where the entry
        \\-- puts her; 25 fell or moved; 26 the map over the view (1.0 Step 18a);
        \\-- 27 the METROIDS page did not leave the entry's count (1.0 Step 18d). A
        \\-- failure prints what it compared.
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr) return emu.read(addr, wram) | (emu.read(addr + 1, wram) << 8) end
        \\local R = {{ frames = {d}, unhandled = {d}, countdown = {d}, open = {d},
        \\  block = {d}, acid = {d}, spike = {d}, pose = {d}, sy = {d}, sx = {d}, map = {d}, scroll = {d},
        \\  cell = {d}, camy = {d}, camx = {d} }}
        \\local APART, SETTLE, STAND, WARP_ROW, LIMIT = {d}, {d}, {d}, {d}, {d}
        \\local POSE_STAND, POSE_MORPH, POSE_HURT, POSE_MORPHHURT, HIT_AFTER = {d}, {d}, {d}, {d}, {d}
        \\LISTN = {{ {d}, {d}, {d}, {d} }}
        \\
    , .{
        lo,                                  hi - 1,                   sorted.len,
        try sym("VarFrameCount"),            try sym("VarUnhandled"),  try sym("VarCountdown"),
        try sym("VarDebugOpen"),             try sym("VarSaveBuf") + 8, try sym("VarAcidDmg"),
        try sym("VarSpikeDmg"),              try sym("VarPose"),       try sym("VarSamusY"),
        try sym("VarSamusX"),                try sym("VarMapIndex"),   try sym("VarScroll"),
        try sym("VarCell"),                  try sym("VarCamY"),       try sym("VarCamX"),
        apart,                               settle,                   stand,
        warp_row,                            limit,                    screen.pose.stand,
        screen.pose.morph,                   pose_hurt,                pose_morph_hurt,
        hit_after,                           counts[0],                counts[1],
        counts[2],                           counts[3],
    });
    try w.print("VIEW_ROWS, VIEW_COLS = {d}, {d}\nR.tilemap = {d}\nSTREAM_FRAMES, pending = {d}, nil\n", .{ view_rows, view_cols, try sym("VarTilemapBuf"), stream_frames });
    try w.print("R.real, R.door, START, MET_ROW, METS_N = {d}, {d}, {d}, {d}, {d}\n", .{ try sym("VarMetReal"), try sym("VarDoorIndex"), fromBcd(warp.start_count), metroids_row, mets[0] });

    // Per entry: its list and row, where it arrives and stands, its pose, and
    // the Game Boy's block, damage and image.
    try w.print("E = {{\n", .{});
    for (lo..hi) |i| {
        const e = sorted[i];
        const r = refs[i];
        const li, const row = debug_tables.warpRow(sorted, i);
        try w.print("  {{ {d}, {d}, {d}, {d}, {d}, {d}, {d}, {{", .{ li, row, e.dest.at.bank, debug_tables.warpCell(e), @intFromBool(e.morph), e.samus_y, e.samus_x });
        for (r.block, 0..) |b, k| try w.print("{s}{d}", .{ if (k == 0) "" else ", ", b });
        try w.print("}}, {d}, {d}, {d}, \"{d} {X}:{X:0>2} {s} chain {X}", .{ r.acid, r.spike, img_of[i - lo] + 1, i, e.dest.at.bank, e.dest.at.cell, @tagName(e.dest.kind), e.chain[0] });
        if (e.n > 1) try w.print(" {X}", .{e.chain[1]});
        if (e.count != warp.start_count) try w.print(" at count {X:0>2}", .{e.count});
        const sc: u8 = @bitCast(world.cellOf(.{ .bank = e.dest.at.bank, .cell = debug_tables.warpCell(e) }).scroll);
        // Her room's entry drops her in from the top, as `ENTER_QUEEN` does on
        // the Game Boy (1.0 Step 6): the `queen` scenario holds her to our Game
        // Boy's fall frame by frame, so neither the arrival nor the stand
        // checks apply.
        // 0 stands; 1 her room, which the `queen` scenario follows; 2 a `doors`
        // entry with no spot, whose loaded state and map alone are graded.
        const how: u8 = if (e.dest.kind == .queen) 1 else if (!e.stand) 2 else 0;
        const top, const left = viewOrigin(e.cam_y, e.cam_x);
        try w.print("\", {d}, {d}, {d}, {d}, {{", .{ sc, how, top, left });
        if (how != 1) for (r.view, 0..) |t, k| try w.print("{s}{d}", .{ if (k == 0) "" else ",", t });
        try w.print("}}, {d} }},\n", .{e.count});
    }
    try w.print("}}\nIMG = {{\n", .{});
    for (images.items) |im| {
        try w.print("  {{", .{});
        for (im, 0..) |h, k| try w.print("{s}{d}", .{ if (k == 0) "" else ",", h });
        try w.print("}},\n", .{});
    }
    try w.print("}}\n", .{});

    try w.print(
        \\
        \\for i = 0, 0x1FFF do emu.write(i, 0, emu.memType.snesSaveRam) end
        \\
        \\local phase, frames, starts = 0, 0, 0
        \\local stopped = false
        \\local function fail(c, what)
        \\  if stopped then return end
        \\  stopped = true
        \\  print(what)
        \\  emu.stop(c)
        \\end
        \\
        \\local function charHash(base)
        \\  local h = 2166136261
        \\  for j = 0, 15 do h = ((h ~ emu.read(base + j, vram)) * 16777619) & 0xFFFFFFFF end
        \\  return h
        \\end
        \\
        \\-- The presses for entry `e`, from play. First, for a count other than
        \\-- the last one's, METROIDS' first rows switched until it is reached:
        \\-- killed in order to go down, revived to come back up (an entry held
        \\-- to the recording's count, 1.0 Step 18f, sits among $47's).
        \\local killed = 0
        \\local function presses(e)
        \\  local p = {{}}
        \\  local want = START - ((e[18] >> 4) * 10 + (e[18] & 15))
        \\  if want ~= killed then
        \\    local from = math.min(want, killed)
        \\    p[#p + 1] = "chord"
        \\    for i = 1, MET_ROW do p[#p + 1] = "down" end
        \\    p[#p + 1] = "a"
        \\    local down, up = from, (METS_N - from) % METS_N
        \\    if down <= up then
        \\      for i = 1, down do p[#p + 1] = "down" end
        \\    else
        \\      for i = 1, up do p[#p + 1] = "up" end
        \\    end
        \\    for r = from, math.max(want, killed) - 1 do
        \\      if r > from then p[#p + 1] = "down" end
        \\      p[#p + 1] = "a"
        \\    end
        \\    p[#p + 1] = "b"
        \\    p[#p + 1] = "b"
        \\    killed = want
        \\  end
        \\  p[#p + 1] = "chord"
        \\  for i = 1, WARP_ROW do p[#p + 1] = "down" end
        \\  p[#p + 1] = "a"
        \\  for i = 1, e[1] do p[#p + 1] = "down" end
        \\  p[#p + 1] = "a"
        \\  local n = LISTN[e[1] + 1]
        \\  local down, up = e[2], (n - e[2]) % n
        \\  if down <= up then
        \\    for i = 1, down do p[#p + 1] = "down" end
        \\  else
        \\    for i = 1, up do p[#p + 1] = "up" end
        \\  end
        \\  p[#p + 1] = "a"
        \\  return p
        \\end
        \\
        \\local PADS = {{ chord = {{ l = true, r = true, start = true }} }}
        \\local k, state, tick, since, P, at, hits, hit, fc, warped = 1, "press", 0, 0, nil, nil, 0, false, nil, nil
        \\local checked = false
        \\-- First the SAMUS page's FULL LOADOUT, its last row, so that enemies
        \\-- the warps land beside cannot end the run in a death.
        \\LOADOUT = {{ "chord", "a", "up", "a", "b", "b" }}
        \\
        \\local function check(e)
        \\  local label = e[12]
        \\  if emu.read(R.real, wram) ~= e[18] then
        \\    fail(27, string.format("%s: count %02x, the entry's %02x", label, emu.read(R.real, wram), e[18]))
        \\    return
        \\  end
        \\  for i = 1, #e[8] do
        \\    local got = emu.read(R.block + i - 1, wram)
        \\    if got ~= e[8][i] then
        \\      fail(21, string.format("%s: $D8%02X %02x, the Game Boy's %02x", label, 7 + i, got, e[8][i]))
        \\      return
        \\    end
        \\  end
        \\  if emu.read(R.acid, wram) ~= e[9] or emu.read(R.spike, wram) ~= e[10] then
        \\    fail(22, string.format("%s: damage %02x %02x, the Game Boy's %02x %02x", label,
        \\      emu.read(R.acid, wram), emu.read(R.spike, wram), e[9], e[10]))
        \\    return
        \\  end
        \\  local img = IMG[e[11]]
        \\  local bad = {{}}
        \\  for c = 0, 255 do
        \\    if img[c + 1] >= 0 and charHash(c * 16) ~= img[c + 1] then bad[#bad + 1] = string.format("%02X", c) end
        \\  end
        \\  if #bad > 0 then
        \\    fail(23, string.format("%s: %d characters differ: %s", label, #bad, table.concat(bad, " ")))
        \\    return
        \\  end
        \\end
        \\
        \\-- On the frame she arrives: the map over the camera's view, slot for
        \\-- slot, as `warp_grade.viewSlot` indexes it.
        \\function view(e)
        \\  if stopped then return end
        \\  local top, left, T = e[15], e[16], e[17]
        \\  local bad, first = 0, nil
        \\  for r = 0, VIEW_ROWS - 1 do
        \\    for c = 0, VIEW_COLS - 1 do
        \\      local slot = ((((top >> 3) + r) & 31) * 32) + (((left >> 3) + c) & 31)
        \\      local got = emu.read(R.tilemap + slot * 2, wram)
        \\      local want = T[r * VIEW_COLS + c + 1]
        \\      if got ~= want then
        \\        bad = bad + 1
        \\        if first == nil then first = string.format("row %d col %d (slot %03X) %02x, the Game Boy's %02x", r, c, slot, got, want) end
        \\      end
        \\    end
        \\  end
        \\  if bad > 0 then fail(26, string.format("%s: %d tiles of the view differ, first %s", e[12], bad, first)) end
        \\end
        \\
        \\-- On the frame she arrives: where the entry puts her, in its pose.
        \\local function arrived(e)
        \\  local pose = emu.read(R.pose, wram)
        \\  local want = e[5] == 1 and POSE_MORPH or POSE_STAND
        \\  if pose ~= want or rd16(R.sy) ~= e[6] or rd16(R.sx) ~= e[7] then
        \\    fail(24, string.format("%s: pose %02x at %04x,%04x, the entry's %02x at %04x,%04x", e[12],
        \\      pose, rd16(R.sy), rd16(R.sx), want, e[6], e[7]))
        \\  end
        \\  at = {{ pose, rd16(R.sy), rd16(R.sx) }}
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  if stopped then return end
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(1, "Fatal") end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(4, "unhandled pose " .. emu.read(R.unhandled, wram)) end
        \\  if frames > LIMIT then fail(2, "phase " .. phase .. " entry " .. k .. " " .. state .. " at frame " .. frames) end
        \\  if phase == 0 and rd16(R.frames) ~= 0 then phase = 1 end
        \\  if phase == 2 and rd16(R.countdown) ~= 0 then phase = 3 end
        \\  if phase == 3 and rd16(R.countdown) == 0 then phase, tick, state, P = 4, 0, "loadout", LOADOUT end
        \\  if phase ~= 4 then return end
        \\  local e = E[k]
        \\  tick = tick + 1
        \\  if state == "loadout" then
        \\    if tick >= #P * APART + APART then k, state, tick, P = 1, "press", 0, presses(E[1]) end
        \\  elseif state == "press" then
        \\    if tick >= #P * APART then state, since = "arrive", 0 end
        \\  elseif state == "arrive" then
        \\    since = since + 1
        \\    -- Arrived once the game runs again: the warp runs with NMI off for
        \\    -- frames on end, and the frame counter stands still until it is done.
        \\    if emu.read(R.open, wram) ~= 0 then
        \\      if since > 2 then fail(3, e[12] .. ": the menu is still up") end
        \\    elseif fc == nil then
        \\      fc, warped = rd16(R.frames), emu.read(R.cell, wram)
        \\    elseif rd16(R.frames) == fc then
        \\      warped = emu.read(R.cell, wram)
        \\    else
        \\      -- The bank, and the cell the warp drew: the camera's, which the
        \\      -- first frame's latch would pick, read as the warp left it.
        \\      local cam = ((rd16(R.camy) >> 4) & 0xF0) | ((rd16(R.camx) >> 8) & 0x0F)
        \\      if emu.read(R.map, wram) + 9 ~= e[3] or warped ~= e[4] or cam ~= e[4] or emu.read(R.scroll, wram) ~= e[13] then
        \\        fail(20, string.format("%s: arrived at %X:%02X drawn as %02X, the camera's %02X, scroll flags %02x, the cell's %02x", e[12],
        \\          emu.read(R.map, wram) + 9, e[4], warped, cam, emu.read(R.scroll, wram), e[13]))
        \\      end
        \\      -- The view once the stream has gone round (1.0 Step 19c): the
        \\      -- warp draws the camera's cell, and a row or column of the next
        \\      -- comes a direction a frame, round-robin on the frame counter.
        \\      -- Read on the frame it arrives, the view could be a row short,
        \\      -- by as many frames as the warp's phase gave it.
        \\      if e[14] ~= 1 then pending = e end
        \\      -- Her room drops her in: the `queen` scenario follows the fall.
        \\      if e[14] == 0 then arrived(e) else at = {{ 0, 0, 0 }} end
        \\      state, since, fc = "settle", 0, nil
        \\    end
        \\    if since > 120 then fail(3, e[12] .. ": the game never ran again after the warp") end
        \\  else
        \\    -- A second of standing, from the frame after she arrives. An enemy's
        \\    -- hit ends it once she has stood long enough to have fallen.
        \\    since = since + 1
        \\    if pending ~= nil and (since >= STREAM_FRAMES or rd16(R.door) ~= 0) then view(pending); pending = nil end
        \\    -- Read before a door she has fallen or walked into runs: its index
        \\    -- is set the frame before (1.0 Step 18d).
        \\    if since < SETTLE and rd16(R.door) ~= 0 and not checked then check(e); checked = true end
        \\    if since == SETTLE and not checked then check(e) end
        \\    if not hit and e[14] == 0 then
        \\      local pose, y, x = emu.read(R.pose, wram), rd16(R.sy), rd16(R.sx)
        \\      if (pose == POSE_HURT or pose == POSE_MORPHHURT) and since > HIT_AFTER then
        \\        hit = true
        \\        hits = hits + 1
        \\      elseif pose ~= at[1] or y ~= at[2] or x ~= at[3] then
        \\        fail(25, string.format("%s: %d frames on, pose %02x at %04x,%04x", e[12], since, pose, y, x))
        \\      end
        \\    end
        \\    if not stopped and since == STAND then
        \\      hit, checked = false, false
        \\      if k == #E then
        \\        print(#E .. " warps, " .. hits .. " hit by an enemy once standing")
        \\        emu.stop(0)
        \\      else
        \\        k, state, tick, P = k + 1, "press", 0, presses(E[k + 1])
        \\      end
        \\    end
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
        \\  local p = {{}}
        \\  if phase == 4 and (state == "press" or state == "loadout") then
        \\    local i = tick // APART + 1
        \\    if i <= #P and tick % APART < 2 then
        \\      local key = P[i]
        \\      p = PADS[key] or {{ [key] = true }}
        \\    end
        \\  end
        \\  emu.setInput(p, 0)
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

// ---- The scenarios Step 4 could not walk to -----------------------------------

/// What a warp makes gradable that a new game's walk could not reach (1.0 Step
/// 4 moved them here). Each is its own run, as the scenarios are.
pub const Scenario = enum {
    /// The first ITEMS entry's orb marked taken on FLAGS, and the warp there
    /// loads no orb; reset, and the next warp does.
    item,
    /// Metroid 01's room: the Alpha on the screen with its fight begun,
    /// killed from the METROIDS page. Its slot is freed, the fight ends as
    /// its death ends one, and the count goes down.
    metroid,
    /// The one entry stood beside a door that branches on the count between
    /// the new game's and one fewer: a Metroid killed from the menu, and the
    /// walk through the door loads the table the ROM gives the new count.
    gated_door,
    /// 1.0 Step 6: her room, and its raster split. The play window at
    /// `queen_frames` frames after the warp, against our Game Boy's at as many
    /// after door $19D, pixel for pixel but where the cart's objects are: the
    /// Game Boy side is the background and window alone (`gb/ppu.zig`).
    queen,
    /// 1.0 Step 10: the energy and missile refills of `$F:$10`, the hatching
    /// Alpha's room, where James saw them missing (2026-09-15, 2026-09-26).
    /// Warped to each, and again after the Alpha is killed from the menu:
    /// every frame for `refill_frames`, each is in OAM with its record's
    /// parts, every pixel its characters colour is the shade the palette it
    /// is drawn in gives, and it blinks into OBP1 as 02:$4DD3 toggles it.
    /// The characters, the parts and both palettes are the ROM's.
    refills,
    /// 1.0 Step 10: `pickup_missileRefill`'s test of `metroidCountReal`
    /// (00:$399C). The missile refill at `collect_place`, ten missiles short,
    /// fills at the new game's count and records nothing; every row of
    /// METROIDS killed, the Queen's last, takes the count to zero; and there
    /// the refill takes the credits branch: not filled, the song request
    /// 00:$39A7 makes, and the pickup held where mode $12 will go.
    refill_credits,
    /// 1.0 Step 13: Arachnus's room (`$D:$C0`), the Spring Ball's WARP entry,
    /// with every item but the Spring Ball. The fight is begun with the
    /// recording's opening shot and its six bombs are handed over as the
    /// enemy rung hands them -- the contact record the hitbox test leaves --
    /// each once it stands again; then Samus jumps at what is left until the
    /// pickup runs. The Spring Ball's bit is set, Arachnus's record is dead,
    /// and warped to again, nothing is loaded.
    spring_ball,
    /// 1.0 Step 27a, James's playthrough: killed Metroids came back. The Alpha
    /// `$A` #$40 killed from the menu mid-fight, and its room left by a warp
    /// before its post-death wait runs out; a wait in a save room; then the
    /// Alpha `$D` #$46 killed with missiles, aimed and fired through the pad.
    /// Its explosion runs its four blasts with its record dead throughout, and
    /// it does not come back.
    missile_kill,
};

/// The `missile_kill` scenario's two Metroids, as bank and spawn number.
const KillAt = struct { bank: u8, number: u8 };
const kill_first: KillAt = .{ .bank = 0xA, .number = 0x40 };
const kill_second: KillAt = .{ .bank = 0xD, .number = 0x46 };
/// Frames after the menu's kill before the warp out. The post-death wait
/// (02:$4039) climbs to $90 on even frames, 288, and an explosion is four
/// blasts of seven passes at 30 Hz, 56: a wait left with less than an
/// explosion to run is one that, stopped by the crossing, ran out
/// mid-explosion at the next kill.
const kill_leave = 2 * 0x90 - 28;

/// The frames the `refills` scenario looks at a refill for, each time.
pub const refill_frames = 64;

/// The frames the `queen` scenario compares: past the Game Boy's fade-in
/// (`FADEOUT` is still walked by length on the cart) and inside her first
/// state, where `zig build queen` holds her still.
pub const queen_frames = [_]usize{ 60, 90, 120 };
/// And the frames it follows Samus through, from the one the warp returns on:
/// `ENTER_QUEEN` puts her at the top of the room and she falls in.
pub const queen_track = 30;

pub fn scenarioCode(c: u8) []const u8 {
    return switch (c) {
        30 => "the warp loaded the orb its flag marked taken",
        31 => "the warp did not load the orb once its flag was reset",
        32 => "the Metroid never appeared with its fight begun",
        33 => "the kill left the Metroid in its slot, its fight running, or the count as it was",
        34 => "the walk through the door never ran it",
        35 => "the door loaded another table than the ROM's for the new count",
        36 => "her room's play window is not the Game Boy's picture",
        37 => "Samus is not where the Game Boy has her in the frames after the warp",
        38 => "a refill is missing from OAM, or drawn with other than its record's parts",
        39 => "a refill's pixels are not the shades its palette gives: it is not seen",
        40 => "a refill never blinked into object palette 1",
        41 => "the missile refill at a count above zero did not fill, or took the credits branch",
        42 => "the METROIDS page, the Queen's row last, did not take the count to zero and back",
        43 => "the missile refill at a count of zero did not take the credits branch (00:$399C)",
        44 => "the Spring Ball was already Samus's, or Arachnus never appeared",
        45 => "Arachnus never stood up to be bombed, or six bombs did not leave the Spring Ball",
        46 => "the Spring Ball was never picked up, or its bit is not set",
        47 => "Arachnus's record is not dead after the pickup, or a second warp loaded it again",
        48 => "the first Metroid never began its fight, or the menu's kill did not end it",
        49 => "the missiles never killed the second Metroid",
        50 => "the second Metroid's explosion was cut short: it came back, or its record left dead",
        else => code(c),
    };
}

/// The METROIDS list's row for a spawn record, and FLAGS' for one.
pub fn blobRow(blob: []const u8, bank: u8, number: u8) ?u8 {
    for (0..blob[0]) |i| {
        const e = blob[1 + i * debug_tables.entry_bytes ..];
        if (e[0] == bank and e[2] == number) return @intCast(i);
    }
    return null;
}

/// The entry beside a door whose script loads another metatile table at one
/// Metroid fewer than the new game's, found from the crawl: the door walked
/// out of the entry's own cell, left or right. Null when there is none.
pub const Gate = struct { entry: usize, door: u16, right: bool, want: u16, before: u16 };

pub fn gatedDoor(a: std.mem.Allocator, rom: []const u8, sorted: []const warp.Entry, walked: []const warp.WalkedDoor) !?Gate {
    const door = @import("door.zig");
    const decoded = try door.decodeRegion(a, door.region(rom) orelse return null);
    const ptrs = door.pointers(rom) orelse return null;
    const rows = warp.thresholds(rom);
    const s0 = try warp.initialState(rom, decoded);
    const mp = offsets.find("metatile_pointers") orelse return null;
    const pointer = struct {
        fn of(r: []const u8, at: usize, tt: u4) u16 {
            return std.mem.readInt(u16, r[at + @as(usize, tt) * 2 ..][0..2], .little);
        }
    };
    for (sorted, 0..) |e, i| for (walked) |wd| {
        if (wd.from.bank != e.dest.at.bank or wd.from.cell != e.dest.at.cell) continue;
        if (wd.dir != .right and wd.dir != .left) continue;
        const now = warp.runScript(decoded, ptrs, rows, s0, wd.door, warp.start_count)[0];
        const then = warp.runScript(decoded, ptrs, rows, s0, wd.door, warp.start_count - 1)[0];
        if (now.tiletable == then.tiletable) continue;
        return .{
            .entry = i,
            .door = wd.door,
            .right = wd.dir == .right,
            .want = pointer.of(rom, mp.romOffset(), then.tiletable),
            .before = pointer.of(rom, mp.romOffset(), now.tiletable),
        };
    };
    return null;
}

/// The root's rows: SAMUS, METROIDS, FLAGS, CLOCK, WARP, READOUT, CONTROLS.
const root_rows = 7;
const samus_row = 0;
pub const metroids_row = 1;
pub const flags_row = 2;
/// `!SlotCount` slots of `!SlotSize`, and the offsets in one.
const slot_count = 16;
const slot_size = 0x20;
const en_number = 0x1D;
const slot_empty: u8 = 0xFF;
/// `metroid_fightActive` with a fight on (02:$6C18). A death leaves it at
/// `Kill.dead`, 02:$6D79.
const fight_on: u8 = 1;

/// The menu-driving half of a scenario's script: the symbols, the presses,
/// the walk through the tree, the warp, and `reboot` (1.0 Step 18e). What a
/// scenario's `main` is written against; `writeRunner` closes it.
pub fn writeMenuPrelude(rom: []const u8, sorted: []const warp.Entry, limit: usize, w: *std.Io.Writer) !void {
    const scenario = @import("scenario.zig");
    const kill = try scenario.Kill.read(rom);
    var counts: [debug_tables.warp_lists.len]usize = @splat(0);
    for (sorted, 0..) |_, i| counts[debug_tables.warpRow(sorted, i)[0]] += 1;
    counts[debug_tables.ending_list] += 1; // ENDING, the QUEEN list's last row

    try w.print(
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr) return emu.read(addr, wram) | (emu.read(addr + 1, wram) << 8) end
        \\local R = {{ frames = {d}, unhandled = {d}, countdown = {d}, open = {d}, block = {d},
        \\  slots = {d}, spawn = {d}, fight = {d}, real = {d}, door = {d}, sy = {d}, sx = {d} }}
        \\local APART, WARP_ROW, ROOT_N, LIMIT = {d}, {d}, {d}, {d}
        \\local SLOTS, SLOT_SIZE, EN_NUMBER, EMPTY = {d}, {d}, {d}, {d}
        \\local DEAD, FIGHT_ON, FIGHT_DIED = {d}, {d}, {d}
        \\LISTN = {{ {d}, {d}, {d}, {d} }}
        \\
    , .{
        try sym("VarFrameCount"), try sym("VarUnhandled"),   try sym("VarCountdown"),
        try sym("VarDebugOpen"),  try sym("VarSaveBuf") + 8, try sym("VarSlots"),
        try sym("VarSpawnFlags"), try sym("VarMetFight"),    try sym("VarMetReal"),
        try sym("VarDoorIndex"),  try sym("VarSamusY"),      try sym("VarSamusX"),
        apart,                    warp_row,
        root_rows,                limit,                     slot_count,
        slot_size,                en_number,                 slot_empty,
        kill.dead,                fight_on,                  kill.dead,
        counts[0],                counts[1],                 counts[2],
        counts[3],
    });

    try w.print(
        \\
        \\for i = 0, 0x1FFF do emu.write(i, 0, emu.memType.snesSaveRam) end
        \\
        \\local phase, frames, starts = 0, 0, 0
        \\local stopped = false
        \\local function fail(c, what)
        \\  if not stopped then
        \\    stopped = true
        \\    print(what)
        \\    emu.stop(c)
        \\  end
        \\  while coroutine.isyieldable() do coroutine.yield() end
        \\end
        \\
        \\PAD = {{}}
        \\local PADS = {{ chord = {{ l = true, r = true, start = true }} }}
        \\local function frame() coroutine.yield() end
        \\local function wait(n) for i = 1, n do frame() end end
        \\local function press(key)
        \\  PAD = PADS[key] or {{ [key] = true }}
        \\  wait(2)
        \\  PAD = {{}}
        \\  wait(APART - 2)
        \\end
        \\-- The shorter way round from row `from` to row `to` of `n`.
        \\local function rows(from, to, n)
        \\  local down, up = (to - from) % n, (from - to) % n
        \\  if down <= up then
        \\    for i = 1, down do press("down") end
        \\  else
        \\    for i = 1, up do press("up") end
        \\  end
        \\end
        \\local function page(root) press("chord"); rows(0, root, ROOT_N); press("a") end
        \\local function warp(list, row)
        \\  page(WARP_ROW); rows(0, list, #LISTN); press("a"); rows(0, row, LISTN[list + 1]); press("a")
        \\  if emu.read(R.open, wram) ~= 0 then fail(3, "A on the warp row did not warp") end
        \\  -- The warp runs with NMI off for frames on end, and a press made
        \\  -- before the game runs again is one it never sees.
        \\  local fc = rd16(R.frames)
        \\  for i = 1, 120 do
        \\    if rd16(R.frames) ~= fc then return end
        \\    frame()
        \\  end
        \\  fail(3, "the game never ran again after the warp")
        \\end
        \\-- The slot holding spawn number `n`, or nil.
        \\local function slotOf(n)
        \\  for s = 0, SLOTS - 1 do
        \\    local b = R.slots + s * SLOT_SIZE
        \\    if emu.read(b, wram) ~= EMPTY and emu.read(b + EN_NUMBER, wram) == n then return s end
        \\  end
        \\  return nil
        \\end
        \\-- 1.0 Step 18e: the reset button. Cartridge RAM survives it, the boot's
        \\-- phases run again, and the title's two Starts, with a record in the
        \\-- slot, load it rather than begin a new game. Back once play has.
        \\local function reboot()
        \\  emu.reset()
        \\  phase, starts, PAD = 0, 0, {{}}
        \\  frame()
        \\end
        \\-- FULL LOADOUT, SAMUS's last row: the enemies the warps land beside
        \\-- cannot end the run in a death.
        \\local function loadout() page({d}); press("up"); press("a"); press("b"); press("b") end
        \\
    , .{samus_row});
}

/// The close of a scenario's script: `main` run as a coroutine, a frame at a
/// time once play has begun, and the title's two Starts that begin it.
pub fn writeRunner(w: *std.Io.Writer) !void {
    try w.print(
        \\
        \\local co = coroutine.create(main)
        \\emu.addEventCallback(function()
        \\  if stopped then return end
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(1, "Fatal") end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(4, "unhandled pose " .. emu.read(R.unhandled, wram)) end
        \\  if frames > LIMIT then fail(2, "phase " .. phase .. " at frame " .. frames) end
        \\  if phase == 0 and rd16(R.frames) ~= 0 then phase = 1 end
        \\  if phase == 2 and rd16(R.countdown) ~= 0 then phase = 3 end
        \\  if phase == 3 and rd16(R.countdown) == 0 then phase = 4 end
        \\  if phase ~= 4 or stopped then return end
        \\  -- A script that ends in `emu.stop(0)` returns, and the emulator may run
        \\  -- a frame more before it stops: under the gate's load it did, and the
        \\  -- dead coroutine's resume failed a passed run with 2 (1.0 Step 22).
        \\  if coroutine.status(co) == "dead" then return end
        \\  local ok, err = coroutine.resume(co)
        \\  if not ok then fail(2, "script: " .. tostring(err)) end
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
        \\  emu.setInput(phase == 4 and PAD or {{}}, 0)
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

pub fn writeScenarioLua(a: std.mem.Allocator, rom: []const u8, sorted: []const warp.Entry, walked: []const warp.WalkedDoor, sc: Scenario, w: *std.Io.Writer) !void {
    const mets = try debug_tables.metroidsBlob(a, rom);
    const flags = try debug_tables.flagsBlob(a, rom);

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The `{s}` warp scenario, 1.0 Step 5c: the `--debug` cart as a new
        \\-- game, driven through the debug menu's own input to a room a new game
        \\-- cannot walk to (`src/warp_grade.zig`).
        \\--
        \\-- Exit codes: 0 held; 1 Fatal; 2 no play, or out of frames; 3 A did not
        \\-- warp; 4 an unrunnable pose; 30 the orb loaded while marked taken;
        \\-- 31 no orb once reset; 32 no Metroid in its fight; 33 the kill left it,
        \\-- its fight or the count; 34 no door ran; 35 the door's table is not the
        \\-- ROM's for the new count; 36 her room is not the Game Boy's picture. A
        \\-- failure prints what it compared.
        \\
    , .{@tagName(sc)});
    try writeMenuPrelude(rom, sorted, 6000, w);

    switch (sc) {
        .item => {
            // The first ITEMS entry, and its orb's row on FLAGS.
            const i = for (sorted, 0..) |e, i| {
                if (e.dest.kind == .item) break i;
            } else return error.NoItemEntry;
            const rec = sorted[i].dest.record.?;
            const frow = blobRow(flags, rec.bank, rec.number) orelse return error.ItemNotOnFlags;
            try w.print(
                \\local ITEM_ROW, FLAG_ROW, FLAGS_N, NUM = {d}, {d}, {d}, {d}
                \\local function main()
                \\  -- Taken, on FLAGS, then the warp: no orb.
                \\  page({d}); rows(0, FLAG_ROW, FLAGS_N); press("a"); press("b"); press("b")
                \\  warp(1, ITEM_ROW); wait(10)
                \\  local f = emu.read(R.spawn + NUM, wram)
                \\  if f ~= DEAD or slotOf(NUM) ~= nil then
                \\    fail(30, string.format("{X}:{X:0>2} #%02X: flag %02x, slot %s", NUM, f, tostring(slotOf(NUM))))
                \\  end
                \\  -- Reset, and warped to again: the orb.
                \\  page({d}); rows(0, FLAG_ROW, FLAGS_N); press("left"); press("b"); press("b")
                \\  warp(1, ITEM_ROW); wait(10)
                \\  if slotOf(NUM) == nil then
                \\    fail(31, string.format("{X}:{X:0>2} #%02X: flag %02x, no slot", NUM, emu.read(R.spawn + NUM, wram)))
                \\  end
                \\  print("the orb: not loaded while taken, loaded once reset")
                \\  emu.stop(0)
                \\end
                \\
            , .{ debug_tables.warpRow(sorted, i)[1], frow, flags[0], rec.number, flags_row, rec.bank, rec.cell, rec.bank, rec.cell, flags_row });
        },
        .metroid => {
            // Bank A's first Alpha's own room (Metroid 01 until 1.0 Step 26's
            // playthrough order), and its row on METROIDS.
            const i = for (sorted, 0..) |e, i| {
                const m = e.dest.metroid orelse continue;
                if (e.dest.kind == .metroid and m.bank == 0xA and m.number == 0x40) break i;
            } else return error.NoMetroidEntry;
            const m = sorted[i].dest.metroid.?;
            const mrow = blobRow(mets, m.bank, m.number) orelse return error.MetroidNotOnList;
            try w.print(
                \\local ROOM_ROW, MET_ROW, METS_N, NUM, REAL_AFTER = {d}, {d}, {d}, {d}, {d}
                \\local function main()
                \\  loadout()
                \\  warp(2, ROOM_ROW)
                \\  local s
                \\  for i = 1, 600 do
                \\    s = slotOf(NUM)
                \\    if s ~= nil and emu.read(R.fight, wram) == FIGHT_ON then break end
                \\    frame()
                \\  end
                \\  if s == nil or emu.read(R.fight, wram) ~= FIGHT_ON then
                \\    fail(32, string.format("{X}:{X:0>2} #%02X: slot %s, fight %d", NUM, tostring(s), emu.read(R.fight, wram)))
                \\  end
                \\  -- Killed from the menu with the fight on: its slot freed, the fight
                \\  -- ended as its death ends one, one fewer.
                \\  page({d}); rows(0, MET_ROW, METS_N); press("a")
                \\  local b = R.slots + s * SLOT_SIZE
                \\  if emu.read(b, wram) ~= EMPTY or emu.read(R.fight, wram) ~= FIGHT_DIED or emu.read(R.real, wram) ~= REAL_AFTER then
                \\    fail(33, string.format("slot %d status %02x, fight %d, count %02x", s, emu.read(b, wram), emu.read(R.fight, wram), emu.read(R.real, wram)))
                \\  end
                \\  press("b"); press("b"); wait(60)
                \\  if slotOf(NUM) ~= nil then fail(33, "a second on, the Metroid is back in slot " .. slotOf(NUM)) end
                \\  print("the Alpha killed on the screen: its slot freed, its fight ended, the count down")
                \\  emu.stop(0)
                \\end
                \\
            , .{ debug_tables.warpRow(sorted, i)[1], mrow, mets[0], m.number, bcdDown(warp.start_count), m.bank, m.cell, metroids_row });
        },
        .gated_door => {
            const g = (try gatedDoor(a, rom, sorted, walked)) orelse return error.NoGatedDoor;
            const e = sorted[g.entry];
            try w.print(
                \\local ROOM_ROW, WANT, BEFORE = {d}, {d}, {d}
                \\local function main()
                \\  loadout()
                \\  warp(2, ROOM_ROW)
                \\  -- The first Metroid killed from the menu: one fewer.
                \\  page({d}); press("a"); press("b"); press("b")
                \\  -- Walked {s} through door ${X}, jumping as the crawl does.
                \\  local ran = false
                \\  for f = 0, 899 do
                \\    PAD = {{ {s} = true, b = (f % 36 < 32) }}
                \\    frame()
                \\    if rd16(R.door) ~= 0 and not ran then ran = rd16(R.door) end
                \\    if ran and rd16(R.door) == 0 then break end
                \\  end
                \\  PAD = {{}}
                \\  if not ran or rd16(R.door) ~= 0 then fail(34, "{X}:{X:0>2}: door ${X} never ran") end
                \\  local got = rd16(R.block + 5)
                \\  if got ~= WANT then
                \\    fail(35, string.format("door ${X} (ran %03x at count %02x): table %04x, the ROM's %04x for the new count (%04x before it)",
                \\      ran, emu.read(R.real, wram), got, WANT, BEFORE))
                \\  end
                \\  print(string.format("door ${X} at one fewer: table %04x, not %04x", WANT, BEFORE))
                \\  emu.stop(0)
                \\end
                \\
            , .{
                debug_tables.warpRow(sorted, g.entry)[1], g.want,                     g.before,
                metroids_row,                              if (g.right) "right" else "left", g.door,
                if (g.right) "right" else "left",          e.dest.at.bank,            e.dest.at.cell,
                g.door,                                    g.door,                    g.door,
            });
        },
        .queen => {
            const queen = @import("queen.zig");
            const target = @import("snes_target.zig");
            const i = for (sorted, 0..) |e, i| {
                if (e.dest.kind == .queen) break i;
            } else return error.NoQueenEntry;
            const gb = try queen.measure(a, rom, queen_frames[queen_frames.len - 1] + 2);
            try w.print("local QUEEN_ROW, VIEW_W, VIEW_H, WIN_LEFT, BAND_TOP = {d}, {d}, {d}, {d}, {d}\nQS = {{", .{
                debug_tables.warpRow(sorted, i)[1], target.view_w, target.view_h, (target.screen_w - target.view_w) / 2, (target.screen_h - target.view_h) / 2,
            });
            // The cart's first frame after the warp has run one pass of play,
            // and the Game Boy's first after door $19D none: it is its second.
            for (gb[1 .. queen_track + 1]) |f| try w.print(" {{ {d}, {d} }},", .{ f.samus_y, f.samus_x });
            try w.print(" }}\nQF = {{\n", .{});
            for (queen_frames) |f| {
                if (!gb[f + 1].complete) return error.QueenFramePartial;
                try w.print("  {{ {d}, \"", .{f});
                for (gb[f + 1].shades) |sh| try w.print("{d}", .{sh});
                try w.print("\" }},\n", .{});
            }
            try w.print(
                \\}}
                \\local OVERSCAN = (239 - 224) // 2
                \\local function shade(px)
                \\  local r = (px >> 16) & 0xFF
                \\  if r > 200 then return 0 elseif r > 120 then return 1
                \\  elseif r > 40 then return 2 else return 3 end
                \\end
                \\-- Every object on the screen, as the pixels it may cover in the
                \\-- play window. The Game Boy side has none: Samus, and the HUD's
                \\-- Metroid, are graded elsewhere.
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
                \\local function compare(q)
                \\  local buf, mask, ref = emu.getScreenBuffer(), objects(), q[2]
                \\  local bad, first, lines = 0, nil, {{}}
                \\  for y = 0, VIEW_H - 1 do
                \\    for x = 0, VIEW_W - 1 do
                \\      local k = y * VIEW_W + x
                \\      if not mask[k] then
                \\        local got = shade(buf[(BAND_TOP + OVERSCAN + y) * 256 + WIN_LEFT + x + 1])
                \\        local want = tonumber(ref:sub(k + 1, k + 1))
                \\        if got ~= want then
                \\          bad = bad + 1
                \\          lines[y] = true
                \\          if first == nil then first = string.format("(%d,%d) %d, the Game Boy's %d", x, y, got, want) end
                \\        end
                \\      end
                \\    end
                \\  end
                \\  if bad > 0 then
                \\    local ls = {{}}
                \\    for y = 0, VIEW_H - 1 do if lines[y] then ls[#ls + 1] = y end end
                \\    fail(36, string.format("frame %d: %d pixels differ on %d lines (%d-%d), first at %s", q[1], bad, #ls, ls[1], ls[#ls], first))
                \\  end
                \\end
                \\local function main()
                \\  warp(3, QUEEN_ROW)
                \\  for f = 1, #QS do
                \\    local y, x = rd16(R.sy), rd16(R.sx)
                \\    if y ~= QS[f][1] or x ~= QS[f][2] then
                \\      fail(37, string.format("frame %d: %04x,%04x, the Game Boy's %04x,%04x", f - 1, y, x, QS[f][1], QS[f][2]))
                \\    end
                \\    frame()
                \\  end
                \\  local t = #QS
                \\  for _, q in ipairs(QF) do
                \\    wait(q[1] - t)
                \\    t = q[1]
                \\    compare(q)
                \\  end
                \\  print("her room at frames " .. QF[1][1] .. ", " .. QF[2][1] .. " and " .. QF[3][1] .. ": the Game Boy's picture")
                \\  emu.stop(0)
                \\end
                \\
            , .{});
        },
        .refills => try writeRefills(a, rom, sorted, mets, false, w),
        .refill_credits => try writeRefills(a, rom, sorted, mets, true, w),
        .spring_ball => try writeSpringBall(rom, sorted, w),
        .missile_kill => try writeMissileKill(sorted, mets, w),
    }

    try writeRunner(w);
}

const Place = struct { bank: u8, cell: u8 };
/// The refills' room: the hatching Alpha's, where James saw both missing.
const refill_place: Place = .{ .bank = 0xF, .cell = 0x10 };
/// The missile refill the scenario collects. Not `refill_place`'s: the warp
/// stands her on the far side of a wall from those (a finding, `docs/
/// phase1.md`), and at `$F:$76` she reaches it with a jump.
const collect_place: Place = .{ .bank = 0xF, .cell = 0x76 };

/// The missile refill the `refill_credits` scenario collects, as the `credits`
/// rung's first variant collects it too.
pub fn collectRow(sorted: []const warp.Entry) !usize {
    return itemRow(sorted, @import("items.zig").Collected.missile_refill, collect_place);
}

fn itemRow(sorted: []const warp.Entry, item: anytype, at: Place) !usize {
    const i = for (sorted, 0..) |e, i| {
        if (e.dest.kind == .item and e.dest.item == item and
            e.dest.at.bank == at.bank and e.dest.at.cell == at.cell) break i;
    } else return error.NoRefillEntry;
    return debug_tables.warpRow(sorted, i)[1];
}

/// The `refills` scenario's body. What it holds the cart to is read out of
/// the ROM: each refill's parts from the metasprite table (01:$5AB1), the
/// characters they name from the common items copy (00:$05FD), and the two
/// object palettes from the survey `screens.live_obp0`/`live_obp1` records.
fn writeRefills(a: std.mem.Allocator, rom: []const u8, sorted: []const warp.Entry, mets: []const u8, credits: bool, w: *std.Io.Writer) !void {
    _ = a;
    const items = @import("items.zig");
    const blocks = @import("blocks.zig");
    const entity = @import("entity.zig");
    const scenario = @import("scenario.zig");
    const kinds = [_]struct { item: items.Collected, sprite: u8, name: []const u8 }{
        .{ .item = .energy_refill, .sprite = items.sprite_energy_refill, .name = "energy" },
        .{ .item = .missile_refill, .sprite = items.sprite_missile_refill, .name = "missile" },
    };

    var rows: [kinds.len]usize = undefined;
    for (kinds, &rows) |k, *r| r.* = try itemRow(sorted, k.item, refill_place);
    const collect_row = try itemRow(sorted, items.Collected.missile_refill, collect_place);
    const m = for (sorted) |e| {
        if (e.dest.kind == .metroid and e.dest.at.bank == refill_place.bank and e.dest.at.cell == refill_place.cell) break e.dest.metroid.?;
    } else return error.NoMetroidEntry;
    const mrow = blobRow(mets, m.bank, m.number) orelse return error.MetroidNotOnList;

    const common = convert.loadGraphicsCopy(rom, convert.load_common_at) orelse return error.NoCommonItems;
    const first: u16 = (common.dest - 0x8000) / 16;
    const ptrs = offsets.find("metasprite_enemies_pointers").?;
    const data = offsets.find("metasprite_enemies_data").?;

    try w.print(
        \\local ROWS, MET_ROW, METS_N, FRAMES = {{ {d}, {d} }}, {d}, {d}, {d}
        \\local OVERSCAN = (239 - 224) // 2
        \\local MISSILE, MISS_ROW, SAMUS_N, CREDITS, SONG_CREDITS, COLLECT_ROW = {d}, {d}, {d}, {d}, {d}, {d}
        \\local S = {{ stage = {d}, unhandled = {d}, cur = {d}, max = {d}, song = {d}, x = {d}, mode = {d} }}
        \\
    , .{
        rows[0],                              rows[1],
        mrow,                                 mets[0],
        refill_frames,                        kinds[1].sprite,
        @intFromEnum(scenario.Row.missiles),  @typeInfo(scenario.Row).@"enum".fields.len,
        try sym("ConstItemCredits"),          try missileRefillSong(rom),
        collect_row,
        try sym("VarItemStage"),              try sym("VarItemUnhandled"),
        try sym("VarCurMissLo"),              try sym("VarMaxMissLo"),
        try sym("VarSongInt"),                try sym("VarOnscreenX"),
        try sym("VarDeathMode"),
    });
    // Each palette as the shade each colour index is shown in.
    try w.print("OBP = {{", .{});
    for ([_]u8{ screens.live_obp0, screens.live_obp1 }, 0..) |p, n| {
        try w.print(" [{d}] = {{ [0] = {d}, {d}, {d}, {d} }},", .{ n, p & 3, (p >> 2) & 3, (p >> 4) & 3, (p >> 6) & 3 });
    }
    try w.print(" }}\nRF, CH = {{}}, {{}}\n", .{});
    for (kinds) |k| {
        const addr = std.mem.readInt(u16, rom[ptrs.romOffset() + @as(usize, k.sprite) * 2 ..][0..2], .little);
        var o = data.romOffset() + (addr - data.gb_addr);
        var parts: usize = 0;
        try w.print("RF[#RF + 1] = {{ name = \"{s}\", tiles = {{", .{k.name});
        while (rom[o] != entity.terminator) : (o += entity.part_bytes) {
            const t = rom[o + 2];
            if (t < first or (t - first) * 16 >= common.len) return error.RefillOutsideCommon;
            try w.print(" [{d}] = true,", .{t});
            parts += 1;
        }
        try w.print(" }}, parts = {d} }}\n", .{parts});
        o = data.romOffset() + (addr - data.gb_addr);
        while (rom[o] != entity.terminator) : (o += entity.part_bytes) {
            const t = rom[o + 2];
            const c = rom[blocks.offsetIn(common.bank, common.src + (t - first) * 16)..][0..16];
            try w.print("CH[{d}] = \"", .{t});
            for (0..8) |y| for (0..8) |x| {
                const b: u3 = @intCast(7 - x);
                try w.print("{d}", .{(((c[2 * y + 1] >> b) & 1) << 1) | ((c[2 * y] >> b) & 1)});
            };
            try w.print("\"\n", .{});
        }
    }
    try w.print(
        \\local function shade(px)
        \\  local r = (px >> 16) & 0xFF
        \\  if r > 200 then return 0 elseif r > 120 then return 1
        \\  elseif r > 40 then return 2 else return 3 end
        \\end
        \\-- Refill `k` for FRAMES frames: in OAM with its record's parts every
        \\-- frame, each coloured pixel of its characters the shade the palette
        \\-- its entry selects gives that index, and at least once in palette 1.
        \\local function look(k, when)
        \\  local rf, oam, blink = RF[k], emu.memType.snesSpriteRam, false
        \\  for f = 1, FRAMES do
        \\    local buf, n, px, ok, pals = emu.getScreenBuffer(), 0, 0, 0, ""
        \\    for i = 0, 127 do
        \\      local x, y, t, at = emu.read(i * 4, oam), emu.read(i * 4 + 1, oam), emu.read(i * 4 + 2, oam), emu.read(i * 4 + 3, oam)
        \\      local ninth = (emu.read(512 + (i >> 2), oam) >> ((i & 3) * 2)) & 1
        \\      if rf.tiles[t] and ninth == 0 and y < 224 then
        \\        n = n + 1
        \\        local pal = (at >> 1) & 7
        \\        pals = pals .. pal
        \\        if pal == 1 then blink = true end
        \\        for dy = 0, 7 do
        \\          for dx = 0, 7 do
        \\            local r = ((at & 0x80) ~= 0) and 7 - dy or dy
        \\            local c = ((at & 0x40) ~= 0) and 7 - dx or dx
        \\            local idx = tonumber(CH[t]:sub(r * 8 + c + 1, r * 8 + c + 1))
        \\            if idx ~= 0 then
        \\              px = px + 1
        \\              local want = OBP[pal] and OBP[pal][idx]
        \\              if shade(buf[(y + dy + OVERSCAN) * 256 + x + dx + 1]) == want then ok = ok + 1 end
        \\            end
        \\          end
        \\        end
        \\      end
        \\    end
        \\    if n ~= rf.parts then
        \\      fail(38, string.format("the %s refill %s, frame %d: %d parts in OAM, its record's %d", rf.name, when, f, n, rf.parts))
        \\    end
        \\    if ok < px then
        \\      fail(39, string.format("the %s refill %s, frame %d: %d of %d pixels its palette's shade (palettes %s)", rf.name, when, f, ok, px, pals))
        \\    end
        \\    frame()
        \\  end
        \\  if not blink then fail(40, string.format("the %s refill %s: %d frames, never in palette 1", rf.name, when, FRAMES)) end
        \\end
        \\-- Ten missiles fewer, on SAMUS's row, and the menu shut.
        \\local function fewer()
        \\  page({d}); rows(0, MISS_ROW, SAMUS_N); press("left"); press("b"); press("b")
        \\  if rd16(S.cur) == rd16(S.max) then fail(41, "SAMUS's missiles row left the count full") end
        \\end
        \\-- The missile refill sits above the floor she is put on: she jumps
        \\-- towards it, its slot's x against hers (`samus_onscreenXPos`, the
        \\-- space the contact test compares), until the pickup starts.
        \\local function touch()
        \\  for i = 1, 180 do
        \\    local x
        \\    for s = 0, SLOTS - 1 do
        \\      local b = R.slots + s * SLOT_SIZE
        \\      if emu.read(b, wram) ~= EMPTY and emu.read(b + 3, wram) == MISSILE then x = emu.read(b + 2, wram) end
        \\    end
        \\    if x == nil then fail(41, "no missile refill in a slot") end
        \\    local me = emu.read(S.x, wram)
        \\    PAD = {{ b = (i % 40 < 30), left = (x < me - 2), right = (x > me + 2) }}
        \\    frame()
        \\    if emu.read(S.stage, wram) ~= 0 then PAD = {{}}; return end
        \\  end
        \\  PAD = {{}}
        \\  fail(41, "jumped for 180 frames towards the missile refill: no pickup")
        \\end
        \\
    , .{samus_row});
    if (!credits) {
        try w.print(
            \\local function main()
            \\  loadout()
            \\  warp(1, ROWS[1]); wait(10)
            \\  look(1, "after the warp")
            \\  -- The Alpha killed from the menu, and the quake it arms run out.
            \\  page({d}); rows(0, MET_ROW, METS_N); press("a"); press("b"); press("b")
            \\  wait(10)
            \\  look(1, "after the Alpha's kill")
            \\  warp(1, ROWS[2]); wait(10)
            \\  look(2, "after the warp")
            \\  print("{X}:{X:0>2}'s refills: drawn, seen and blinking, before and after the Alpha's kill")
            \\  emu.stop(0)
            \\end
            \\
        , .{ metroids_row, refill_place.bank, refill_place.cell });
        return;
    }
    try w.print(
        \\local function main()
        \\  loadout()
        \\  -- Collected at a count above zero: filled, and nothing recorded.
        \\  warp(1, COLLECT_ROW); wait(10)
        \\  local count = emu.read(R.real, wram)
        \\  fewer()
        \\  touch()
        \\  for i = 1, 600 do
        \\    if emu.read(S.stage, wram) == 0 then break end
        \\    frame()
        \\  end
        \\  if rd16(S.cur) ~= rd16(S.max) or emu.read(S.unhandled, wram) ~= 0 or emu.read(S.stage, wram) ~= 0 then
        \\    fail(41, string.format("count %02x: missiles %03x of %03x, recorded %02x, stage %d", count,
        \\      rd16(S.cur), rd16(S.max), emu.read(S.unhandled, wram), emu.read(S.stage, wram)))
        \\  end
        \\  -- Every row of METROIDS killed; the Queen's, last, takes the count
        \\  -- from one to zero, back, and to zero again.
        \\  page({d})
        \\  -- Right kills and leaves one already dead alone (the Alpha's).
        \\  for r = 1, METS_N - 1 do press("right"); press("down") end
        \\  local one = emu.read(R.real, wram)
        \\  press("a")
        \\  local zero = emu.read(R.real, wram)
        \\  press("a")
        \\  local back = emu.read(R.real, wram)
        \\  press("a")
        \\  if one ~= 1 or zero ~= 0 or back ~= 1 or emu.read(R.real, wram) ~= 0 then
        \\    fail(42, string.format("the count %02x before her, %02x, %02x and %02x after", one, zero, back, emu.read(R.real, wram)))
        \\  end
        \\  press("b"); press("b"); wait(10)
        \\  -- And collected at zero: the credits, not the refill -- game mode $12,
        \\  -- the fade, thirty frames on (1.0 Step 22; until then the pickup held
        \\  -- at CREDITS with the item recorded).
        \\  fewer()
        \\  touch()
        \\  wait(30)
        \\  if emu.read(S.mode, wram) ~= 0x12 or emu.read(S.stage, wram) ~= 0 or emu.read(S.unhandled, wram) ~= 0 or
        \\      rd16(S.cur) == rd16(S.max) or emu.read(S.song, wram) ~= SONG_CREDITS then
        \\    fail(43, string.format("mode %02x, stage %d, recorded %02x, missiles %03x of %03x, song request %02x", emu.read(S.mode, wram),
        \\      emu.read(S.stage, wram), emu.read(S.unhandled, wram), rd16(S.cur), rd16(S.max), emu.read(S.song, wram)))
        \\  end
        \\  print("{X}:{X:0>2}'s missile refill fills; the METROIDS page, the Queen last, takes the count to zero, and there it takes the credits branch")
        \\  emu.stop(0)
        \\end
        \\
    , .{ metroids_row, collect_place.bank, collect_place.cell });
}

/// The `spring_ball` scenario's body.
fn writeSpringBall(rom: []const u8, sorted: []const warp.Entry, w: *std.Io.Writer) !void {
    const items = @import("items.zig");
    const scenario = @import("scenario.zig");
    const i = for (sorted, 0..) |e, i| {
        if (e.dest.kind == .item and e.dest.item == items.Collected.spring_ball) break i;
    } else return error.NoSpringEntry;
    const rec = sorted[i].dest.record.?;
    const bit = (try items.bitFor(rom, .spring_ball)) orelse return error.NoSpringBit;
    try w.print(
        \\local SPRING_ROW, NUM, SPRING, ROW_SPRING, SAMUS_N = {d}, {d}, {d}, {d}, {d}
        \\local ITEM_SPRITE = {d}
        \\local A = {{ items = {d}, stage = {d}, x = {d}, collw = {d}, colle = {d}, colld = {d}, health = {d} }}
        \\-- Arachnus's slot base, or nil.
        \\local function arach()
        \\  local s = slotOf(NUM)
        \\  return s and R.slots + s * SLOT_SIZE
        \\end
        \\-- A contact on Arachnus's slot, as the hitbox test leaves one for the
        \\-- enemy pass: the enemy rung's lever (`enemy_oracle.Hit`).
        \\local function hit(b, weapon, dir)
        \\  local off = b - R.slots
        \\  emu.write(A.collw, weapon, wram)
        \\  emu.write(A.colle, off & 0xFF, wram)
        \\  emu.write(A.colle + 1, off >> 8, wram)
        \\  emu.write(A.colld, dir, wram)
        \\end
        \\local function main()
        \\  loadout()
        \\  page({d}); rows(0, ROW_SPRING, SAMUS_N); press("a"); press("b"); press("b")
        \\  if emu.read(A.items, wram) & SPRING ~= 0 then fail(44, "SAMUS's Spring Ball row left the bit set") end
        \\  warp(1, SPRING_ROW); wait(10)
        \\  local b = arach()
        \\  if b == nil then fail(44, "{X}:{X:0>2}: no slot holds #" .. NUM) end
        \\  -- The recording's opening shot (part 07 frame 1 097): the ice beam.
        \\  hit(b, 0x01, 0x02)
        \\  -- Each bomb once it stands (state 5) and the last one's stun is over.
        \\  for n = 1, 6 do
        \\    local ok = false
        \\    for f = 1, 600 do
        \\      frame()
        \\      if emu.read(b + 7, wram) == 5 and emu.read(b + 6, wram) == 0 then ok = true; break end
        \\    end
        \\    if not ok then fail(45, string.format("bomb %d: state %d, stun %02x after 600 frames", n, emu.read(b + 7, wram), emu.read(b + 6, wram))) end
        \\    hit(b, 0x09, 0xFF)
        \\    wait(2)
        \\  end
        \\  wait(4)
        \\  if emu.read(b + 3, wram) ~= ITEM_SPRITE or emu.read(A.health, wram) ~= 0 then
        \\    fail(45, string.format("six bombs: sprite %02x, health %d", emu.read(b + 3, wram), emu.read(A.health, wram)))
        \\  end
        \\  -- To it, jumping, its x against hers, until the pickup starts.
        \\  local got = false
        \\  for f = 1, 600 do
        \\    local me, x = emu.read(A.x, wram), emu.read(b + 2, wram)
        \\    PAD = {{ b = (f % 40 < 30), left = (x < me - 2), right = (x > me + 2) }}
        \\    frame()
        \\    if emu.read(A.stage, wram) ~= 0 then got = true; break end
        \\  end
        \\  PAD = {{}}
        \\  if not got then fail(46, "600 frames towards the Spring Ball: no pickup") end
        \\  for f = 1, 900 do
        \\    if emu.read(A.stage, wram) == 0 then break end
        \\    frame()
        \\  end
        \\  if emu.read(A.items, wram) & SPRING == 0 then
        \\    fail(46, string.format("the pickup ran and ended (stage %d): items %02x", emu.read(A.stage, wram), emu.read(A.items, wram)))
        \\  end
        \\  wait(10)
        \\  local f = emu.read(R.spawn + NUM, wram)
        \\  if f ~= DEAD or slotOf(NUM) ~= nil then
        \\    fail(47, string.format("after the pickup: #%02X flag %02x, slot %s", NUM, f, tostring(slotOf(NUM))))
        \\  end
        \\  warp(1, SPRING_ROW); wait(10)
        \\  if slotOf(NUM) ~= nil then fail(47, "warped to again: #" .. NUM .. " is back in slot " .. slotOf(NUM)) end
        \\  print("{X}:{X:0>2}: Arachnus bombed six times, its Spring Ball picked up and its bit set; not there again")
        \\  emu.stop(0)
        \\end
        \\
    , .{
        debug_tables.warpRow(sorted, i)[1],          rec.number,
        @as(u8, 1) << bit,                           @intFromEnum(scenario.Row.spring),
        @typeInfo(scenario.Row).@"enum".fields.len,  spring_item_sprite,
        try sym("VarItems"),                         try sym("VarItemStage"),
        try sym("VarOnscreenX"),                     try sym("VarCollWeapon"),
        try sym("VarCollEnemy"),                     try sym("VarCollWeaponDir"),
        try sym("VarArachHealth"),                   samus_row,
        rec.bank,                                    rec.cell,
        rec.bank,                                    rec.cell,
    });
}

/// The `missile_kill` scenario's body. The second kill is played, not handed
/// over as the enemy rung hands its hits: the defects it guards lived in the
/// kill's own pass and in what a room left behind, and a contact record is
/// not a missile.
fn writeMissileKill(sorted: []const warp.Entry, mets: []const u8, w: *std.Io.Writer) !void {
    var rows: [2]usize = undefined;
    var mrow: u8 = undefined;
    for ([_]KillAt{ kill_first, kill_second }, &rows, 0..) |k, *r, n| {
        const i = for (sorted, 0..) |e, i| {
            const m = e.dest.metroid orelse continue;
            if (e.dest.kind == .metroid and m.bank == k.bank and m.number == k.number) break i;
        } else return error.NoMetroidEntry;
        r.* = debug_tables.warpRow(sorted, i)[1];
        if (n == 0) mrow = blobRow(mets, k.bank, k.number) orelse return error.MetroidNotOnList;
    }
    const save = for (sorted, 0..) |e, i| {
        if (e.dest.kind == .station) break debug_tables.warpRow(sorted, i);
    } else return error.NoStationEntry;
    try w.print(
        \\local K = {{ FIRST = {d}, FIRST_MET = {d}, FIRST_NUM = {d}, SECOND = {d}, NUM = {d},
        \\  SAVE_LIST = {d}, SAVE = {d}, METS_N = {d}, LEAVE = {d}, AFTER = {d},
        \\  MST = {d}, CUT = {d}, ONX = {d}, ONY = {d}, DYING = 0x80, EXP_LO = 0xE2, EXP_HI = 0xE7 }}
        \\local function main()
        \\  loadout()
        \\  warp(2, K.FIRST)
        \\  for i = 1, 600 do
        \\    if slotOf(K.FIRST_NUM) ~= nil and emu.read(R.fight, wram) == FIGHT_ON then break end
        \\    frame()
        \\  end
        \\  if slotOf(K.FIRST_NUM) == nil then fail(48, "{X} #{X:0>2}: no fight") end
        \\  page({d}); rows(0, K.FIRST_MET, K.METS_N); press("a"); press("b"); press("b")
        \\  if emu.read(R.fight, wram) ~= FIGHT_DIED then fail(48, "fight " .. emu.read(R.fight, wram) .. " after the menu's kill") end
        \\  -- Out before its wait runs out, and somewhere it can.
        \\  wait(K.LEAVE)
        \\  warp(K.SAVE_LIST, K.SAVE)
        \\  wait(120)
        \\  warp(2, K.SECOND)
        \\  press("select")
        \\  -- At it until it dies: faced on the shot, closed on from afar, left
        \\  -- when too near to hit, aimed up when it is above, jumped at when it
        \\  -- is above the view.
        \\  local died = false
        \\  for f = 1, 3000 do
        \\    local s = slotOf(K.NUM)
        \\    local p = {{}}
        \\    if s ~= nil then
        \\      local b = R.slots + s * SLOT_SIZE
        \\      local ey, ex = emu.read(b + 1, wram), emu.read(b + 2, wram)
        \\      local onx, ony = emu.read(K.ONX, wram), emu.read(K.ONY, wram)
        \\      if f % 16 < 3 then
        \\        p.right, p.left = ex > onx + 4, ex + 4 < onx
        \\      elseif math.abs(ex - onx) > 48 then
        \\        p.right, p.left = ex > onx, ex < onx
        \\      elseif math.abs(ex - onx) < 24 then
        \\        p.right, p.left = (f // 120) % 2 == 0, (f // 120) % 2 == 1
        \\        p.b = f % 40 < 12
        \\      end
        \\      p.up = ey + 16 < ony or (ey < ony and (f // 16) % 2 == 1)
        \\      p.y = f % 16 >= 3 and f % 16 < 5
        \\      if ey >= 0xE0 then p.up = true; p.b = f % 40 < 24 end
        \\    end
        \\    PAD = p
        \\    frame()
        \\    if emu.read(K.MST, wram) == K.DYING then died = true; break end
        \\  end
        \\  PAD = {{}}
        \\  if not died then fail(49, "{X} #{X:0>2}: 3000 frames of missiles") end
        \\  -- The explosion: dead throughout, and only ever an explosion frame.
        \\  for f = 1, 400 do
        \\    local fl, s = emu.read(R.spawn + K.NUM, wram), slotOf(K.NUM)
        \\    local spr = s and emu.read(R.slots + s * SLOT_SIZE + 3, wram)
        \\    if fl ~= DEAD or (spr and (spr < K.EXP_LO or spr > K.EXP_HI or emu.read(K.MST, wram) ~= K.DYING)) then
        \\      fail(50, string.format("frame %d of its death: flag %02x, slot %s, sprite %s, metroid_state %02x, wait %02x",
        \\        f, fl, tostring(s), spr and string.format("%02x", spr) or "-", emu.read(K.MST, wram), emu.read(R.fight, wram)))
        \\    end
        \\    frame()
        \\  end
        \\  if emu.read(K.MST, wram) ~= 0 or emu.read(K.CUT, wram) ~= 0 or emu.read(R.real, wram) ~= K.AFTER then
        \\    fail(50, string.format("after it: metroid_state %02x, frozen %d, count %02x",
        \\      emu.read(K.MST, wram), emu.read(K.CUT, wram), emu.read(R.real, wram)))
        \\  end
        \\  print("{X} #{X:0>2} killed by missiles after {X} #{X:0>2}'s wait was left: four blasts, dead throughout, and gone")
        \\  emu.stop(0)
        \\end
        \\
    , .{
        rows[0],                            mrow,
        kill_first.number,                  rows[1],
        kill_second.number,                 save[0],
        save[1],                            mets[0],
        kill_leave,                         bcdDown(bcdDown(warp.start_count)),
        try sym("VarMetState"),             try sym("VarCutscene"),
        try sym("VarOnscreenX"),            try sym("VarOnscreenY"),
        kill_first.bank,                    kill_first.number,
        metroids_row,                       kill_second.bank,
        kill_second.number,                 kill_second.bank,
        kill_second.number,                 kill_first.bank,
        kill_first.number,
    });
}

/// `SPRITE_SPRING_BALL_ITEM`, what the sixth bomb turns Arachnus into (02:$5260).
const spring_item_sprite: u8 = 0x95;

/// The song request `pickup_missileRefill`'s credits branch makes, read out of
/// the ROM: 00:$39A7 `LD A,$08`, stored to `songInterruptionRequest`.
fn missileRefillSong(rom: []const u8) !u8 {
    const blocks = @import("blocks.zig");
    const o = blocks.offsetIn(0, 0x39A7);
    if (rom[o] != 0x3E or rom[o + 2] != 0xEA or rom[o + 3] != 0xDE or rom[o + 4] != 0xCE) return error.UnexpectedCreditsBranch;
    return rom[o + 1];
}

fn bcdDown(v: u8) u8 {
    return if (v & 0x0F == 0) v - 7 else v - 1;
}

fn fromBcd(v: u8) usize {
    return @as(usize, v >> 4) * 10 + (v & 0x0F);
}

// ---- The fault ----------------------------------------------------------------

/// The fault the rung is held to: every two-script chain in the cart's
/// `warp_data` cut to its last script, the door alone, so the room is entered
/// with whatever the warp before it left loaded. Patched into a copy of a
/// built cart; returns how many chains were cut.
pub fn truncateChains(bytes: []u8, rom: inject.Rom) !usize {
    const layout = @import("snes_layout.zig");
    const addr = inject.blobAddress(rom, layout.Class.debug, @intFromEnum(debug_tables.Which.warp_data)) orelse return Error.NoSymbol;
    const at = try inject.fileOffset(addr);
    const n = bytes[at];
    var cut: usize = 0;
    for (0..n) |i| {
        const d = bytes[at + 1 + i * debug_tables.warp_bytes ..][0..debug_tables.warp_bytes];
        if (d[0] != 2) continue;
        d[0] = 1;
        d[1] = d[3];
        d[2] = d[4];
        d[3] = 0;
        d[4] = 0;
        cut += 1;
    }
    return cut;
}

// ---- The `doors` rung (1.0 Step 18a) -------------------------------------------

/// Door entries a case cart carries, as the WARP page's runs carry about
/// twenty each.
pub const door_shard_entries: usize = 20;

pub fn doorShards(n: usize) usize {
    return (n + door_shard_entries - 1) / door_shard_entries;
}

/// The `--debug` cart with the WARP page's four lists given over to
/// `entries`: all on its first list (`debug_tables.listOf` puts `.door`
/// there), in the order given, and the other three empty. Everything else is
/// the shipped debug cart's, so the menu's own input reaches them as it
/// reaches the real page.
pub fn doorCart(a: std.mem.Allocator, rom: []const u8, set: convert.Set, boot: screen.Boot, entries: []const warp.Entry) !inject.Rom {
    const blobs = try a.dupe(convert.Blob, set.debug);
    const wb = try debug_tables.warpBlobs(a, rom, entries);
    for (debug_tables.warp_lists, wb.lists) |wl, l| blobs[@intFromEnum(wl)].bytes = l;
    blobs[@intFromEnum(debug_tables.Which.warp_data)].bytes = wb.data;
    var s = set;
    s.debug = blobs;
    var diag: inject.Diagnosis = .{};
    var r = try inject.build(a, s, boot, &diag);
    try inject.enableDebug(&r);
    return r;
}

/// The rung's fault: `LoadMetaBase`'s `AND #$000F` made `AND #$0000`, so the
/// metatiles are read from table 0's base whatever table is loaded. The
/// loaded state and the characters are still right; only the map is not.
/// Patched into a copy of a built cart, by the bytes at the label.
pub fn metaBaseFault(bytes: []u8) !void {
    const at = inject.symbolOffset("LoadMetaBase") orelse return Error.NoSymbol;
    const want = [_]u8{ 0x29, 0x0F, 0x00 };
    const i = std.mem.indexOf(u8, bytes[at..][0..12], &want) orelse return Error.NoSymbol;
    bytes[at + i + 1] = 0x00;
}

/// The `counts` rung's fault (1.0 Step 18d): `IF_MET_LESS`'s branch
/// inverted, its `bcs` after `cmp.w !MetReal` made `bcc`, so a door takes its
/// branch above its threshold and walks past it at and below. Patched into a
/// copy of a built cart, by the bytes after the label.
pub fn metLessFault(bytes: []u8) !void {
    const at = inject.symbolOffset("StepDoorScript_metless") orelse return Error.NoSymbol;
    const real = inject.symbol("VarMetReal") orelse return Error.NoSymbol;
    // `cmp.w !MetReal`, `rep #$30`, `bcs`.
    const want = [_]u8{ 0xCD, @truncate(real), @truncate(real >> 8), 0xC2, 0x30, 0xB0 };
    const i = std.mem.indexOf(u8, bytes[at..][0..48], &want) orelse return Error.NoSymbol;
    bytes[at + i + 5] = 0x90;
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the Game Boy's reference: each chain runs, and leaves what the warp table says" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const built = try warp.build(a, rom, try warp.loadWalked(a, rom));
    const sorted = try debug_tables.warpOrder(a, rom, built.entries);
    // At each entry's count: a lava room held to the recording (1.0 Step 18f)
    // is drawn as the recording found it only at the recording's count.
    const refs = try references(a, rom, sorted, shard_count, true);
    var differ: usize = 0;
    for (sorted, refs) |e, r| {
        const t = warp.tilesetOfBlock(rom, r.block) orelse return error.UnreadBlock;
        if (!t.eql(e.tileset)) {
            differ += 1;
            std.debug.print("differs: {X}:{X:0>2} {s} chain {X} {X}\n", .{ e.dest.at.bank, e.dest.at.cell, @tagName(e.dest.kind), e.chain[0], e.chain[1] });
        }
    }
    try testing.expectEqual(@as(usize, 0), differ);
}

test "every cell a walked room settles draws as our Game Boy drew it (1.0 Step 18c)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const walked = try warp.loadWalked(a, rom);
    const asg = try warp.assignWalked(a, rom, walked);
    const got = try cellsDrawn(a, rom, asg, walked);
    // Release Step 0, on the committed crawler's crawl (it was 484 cells and
    // 2 unloadable on the one cached before it).
    try testing.expectEqual(@as(usize, 558), got.cells);
    try testing.expectEqual(@as(usize, 0), got.differ);
    try testing.expectEqual(@as(usize, 8), got.unloadable);
    // The fault: the static reading alone, the crawl's arrivals not laid over
    // it, draws 211 of the 558 differently.
    const static = try screens.assign(a, rom);
    const faulted = try cellsDrawn(a, rom, static, walked);
    try testing.expectEqual(@as(usize, 211), faulted.differ);
}

test "every warp draws a cell in use, the camera's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const roster = @import("roster.zig");
    const built = try warp.build(a, rom, try warp.loadWalked(a, rom));
    var w = try roster.world(a, rom);
    defer w.deinit(a);
    var moved: usize = 0;
    for (built.entries) |e| {
        const c = debug_tables.warpCell(e);
        try testing.expect(w.cellOf(.{ .bank = e.dest.at.bank, .cell = c }).inUse());
        if (c != e.dest.at.cell) moved += 1;
    }
    // Two Metroid records sit in blank cells ($D:$23, $B:$57), drawn beside.
    try testing.expect(moved >= 2);
}

test "every door script's operations are ones the cart's interpreter runs (1.0 Step 18a)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const door = @import("door.zig");

    // What `StepDoorScript`'s dispatch compares the opcode's high nibble for,
    // read out of the engine's own source: `and.b #$F0` then a `cmp.b #$X0`
    // per arm, and zero (the copy) by falling through the `and`.
    const src = @embedFile("engine_asm");
    const from = std.mem.indexOf(u8, src, "\nStepDoorScript:") orelse return error.NoDispatch;
    const len = std.mem.indexOf(u8, src[from..], "\n.tiletable") orelse return error.NoDispatch;
    const body = src[from..][0..len];
    var handled: [16]bool = @splat(false);
    handled[0] = std.mem.indexOf(u8, body, "jmp .copy") != null;
    var it = std.mem.splitSequence(u8, body, "cmp.b #$");
    _ = it.next();
    while (it.next()) |rest| {
        const v = std.fmt.parseInt(u8, rest[0..2], 16) catch continue;
        if (v & 0x0F == 0) handled[v >> 4] = true;
    }
    // `FADEOUT` is waited, not dispatched: its frames are `OpExtraFrames`'.
    const engine = @embedFile("engine_bin");
    const extra = inject.symbolOffset("OpExtraFrames") orelse return error.NoSymbol;
    const fade_waited = engine[extra + 0xA] != 0;

    var decoded = try door.decodeRegion(a, door.region(rom).?);
    const ptrs = door.pointers(rom).?;
    var ran: usize = 0;
    var unhandled: usize = 0;
    for (0..door.pointer_count) |i| {
        const ops = screens.scriptOps(decoded, ptrs, i) orelse continue;
        ran += 1;
        for (ops) |op| {
            const nib: u4 = switch (op) {
                .copy, .load => 0, // a `LOAD` is converted to the copy it makes
                .tiletable => 1,
                .collision => 2,
                .solidity => 3,
                .warp => 4,
                .escape_queen => 5,
                .damage => 6,
                .exit_queen => 7,
                .enter_queen => 8,
                .if_met_less => 9,
                .fadeout => 0xA,
                .song => 0xC,
                .item => 0xD,
                .end => continue,
            };
            if (handled[nib] or (nib == 0xA and fade_waited)) continue;
            unhandled += 1;
            std.debug.print("door ${X:0>3}: opcode ${X}0 has no arm\n", .{ i, nib });
        }
    }
    try testing.expectEqual(@as(usize, 497), ran);
    try testing.expectEqual(@as(usize, 0), unhandled);
    decoded.deinit(a);
}
