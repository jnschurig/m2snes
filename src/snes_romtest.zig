//! The Mesen2 test for the finished cart, generated from the reference render.
//!
//! The expected picture is baked in rather than recomputed on the emulator side:
//! the script carries the two 256x256 screens `snes_render.screenAt` draws and
//! cuts the 160x144 play window out of them at whatever camera the engine
//! reports, then compares that against what the PPU actually put on the screen.
//! The same render feeds the PNG beside the ROM, so what a person holds up
//! against the television and what the gate diffs cannot drift apart.
//!
//! Step 12a baked the window rather than the screen, because the camera was
//! driven by the d-pad and started where the boot record put it. Step 13 gave
//! the camera Samus to follow, and where she comes to rest is a property of the
//! jump and fall arcs and of the converted collision data - not something this
//! side can predict without reimplementing the physics. Baking the screen and
//! cutting the window on the emulator side turns the camera position from a
//! thing the test has to predict into a thing it reads back.
//!
//! Mesen2 swallows `emu.log` in testrunner mode and sandboxes lua's `io`, so the
//! exit code is the only channel there is. The codes are a small protocol,
//! documented in the generated script and read back by `verify.zig`.

const std = @import("std");
const convert = @import("snes_convert.zig");
const render = @import("snes_render.zig");
const screen = @import("snes_screen.zig");
const target = @import("snes_target.zig");
const screens = @import("screens.zig");
const physics = @import("physics.zig");
const sprites = @import("sprites.zig");
const entity = @import("entity.zig");
const transition = @import("transition.zig");
const oracle = @import("oracle.zig");
const map_mod = @import("map.zig");
const offsets = @import("offsets.zig");
const save = @import("save.zig");
const inject = @import("snes_inject.zig");
const room = @import("room.zig");
const items_mod = @import("items.zig");
const blocks_mod = @import("blocks.zig");
const tileset = @import("tileset.zig");
const death = @import("death.zig");
const title_oracle = @import("title_oracle.zig");
const pause_oracle = @import("pause_oracle.zig");
const title_super = @import("title_super.zig");

/// One byte of an engine constant or variable address, by symbol name. Step 12e
/// needs two dozen of them in one table and the inline `@truncate(inject.symbol(
/// ...) orelse return ...)` does not read as anything at that count.
fn symByte(name: []const u8) !u8 {
    return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
}

/// A horizontal direction the boot cell blocks and one it does not, read out of
/// the same scroll byte the engine reads, so the test asserts what the ROM says
/// rather than what this particular screen happens to do.
///
/// Both have to be horizontal now. The gate drives the camera by walking Samus,
/// and walking is the only input that moves her sideways; up and down come from
/// the jump and fall arcs and go where the arcs go.
const Plan = struct {
    wall: screen.Dir,
    open: screen.Dir,
    /// The pixel the camera may not pass on the blocked edge, and which side of
    /// it is the legal one: `+1` when the clamp is an upper bound, `-1` when it
    /// is a lower one.
    wall_clamp: u16,
    wall_sign: i8,
    /// The cell holding the open edge leads into.
    after_open: u8,
};

fn planFor(set: convert.Set, boot: screen.Boot) !Plan {
    const cells = set.map_cells[boot.map_index].bytes;
    const scroll = cells[@as(usize, boot.cell) * convert.cell_bytes + 1];

    var wall: ?screen.Dir = null;
    var open: ?screen.Dir = null;
    for ([_]screen.Dir{ .right, .left }) |dir| {
        if (screen.permits(scroll, dir)) {
            // Only usable if the grid actually has a cell that way.
            if (open == null and screen.neighbour(boot.cell, dir) != null) open = dir;
        } else if (wall == null) wall = dir;
    }
    const w = wall orelse return error.BootCellHasNoWall;
    const o = open orelse return error.BootCellHasNoOpening;

    return .{
        .wall = w,
        .open = o,
        .wall_clamp = if (w == .right) screen.max_x else screen.min_x,
        .wall_sign = if (w == .right) 1 else -1,
        .after_open = screen.neighbour(boot.cell, o).?,
    };
}

/// Operand bytes following each opcode, indexed by its high nibble. **The same
/// table as `OperandBytes` in `engine/main.asm`**, and duplicated here for the
/// reason the gate bakes the screen render rather than recomputing it: the
/// point of the check is that the cart walks the stream correctly, and a walker
/// that shared the engine's table would share a wrong stride with it.
const operand_bytes = [16]u8{ 10, 0, 0, 0, 1, 0, 2, 0, 8, 3, 0, 0, 0, 0, 0, 0 };

/// Where the boot record's own door script warps to, walked out of the
/// *converted* stream the cart will walk.
///
/// The bank is already rebased to the port's 0-6 by `snes_convert.convertOp`,
/// so this is the number the engine puts in `!MapIndex` and not the Game Boy's
/// $9-$F. The position byte packs the destination screen as (row << 4) | col,
/// which is the layout `room.zig` pinned by watching the Game Boy's own
/// `handleWarp` consume it.
const Warp = struct { bank: u8, row: u4, col: u4 };

/// The four `waitOneFrame`s at 00:$3734, and the jingle a major item gets.
///
/// Both from the ROM: the waits are four `call $2C5E`s and the jingle is the
/// `$0160` 00:$3753-$3758 writes into the countdown. Both are also *measured*,
/// on the B11 recording at stride 1 -- the item bit lands four frames after
/// Samus freezes on all four of its pickups, and the freeze runs 358, 103, 366
/// and 359 frames against the 356 and 100 these two numbers predict. The
/// remainder is the second wait loop, which is as long as the enemy pass takes
/// to delete the orb and is deliberately not a constant here.
const item_wait_frames: u16 = 4;
const item_jingle_frames: u16 = 0x0160;
/// How long each half of the bomb-jump gating test holds the jump button.
/// Long enough that a ball which was going to jump has, short enough that the
/// half which must *not* jump is still a real wait rather than a glance.
const bomb_try_frames: u16 = 180;

fn warpTarget(set: convert.Set, boot: screen.Boot) ?Warp {
    const ptrs = set.door_pointers.bytes;
    const at = @as(usize, boot.door_index) * 2;
    if (at + 1 >= ptrs.len) return null;
    var pos: usize = std.mem.readInt(u16, ptrs[at..][0..2], .little);

    const ops = set.doors.bytes;
    while (pos < ops.len) {
        const op = ops[pos];
        if (op == 0xFF) return null; // the stream's terminator
        const hi = op >> 4;
        if (hi == 0x4) {
            if (pos + 1 >= ops.len) return null;
            const at_pos = ops[pos + 1];
            return .{ .bank = op & 0x0F, .row = @truncate(at_pos >> 4), .col = @truncate(at_pos & 0x0F) };
        }
        pos += 1 + operand_bytes[hi];
    }
    return null;
}

/// The direction the gate drives its crossing in, and it has to be one of the
/// four or the draw does not happen at all.
///
/// **Phase 8 wrote only the door index until Step 6**, which left `!TransDir`
/// at zero -- and zero is the arm 00:$2938 falls through to: no strips, no
/// waits, nothing drawn. The crossing was graded on its re-seat and its
/// duration and never on its picture, which is exactly how `WarpDraw` came to
/// be ported with no rung that noticed when it was taken out again.
///
/// Rightward, because the choice has to be *some* direction and this one is
/// the same edge the walking phases already use. The camera scroll that would
/// follow the script is not driven here: the phase clears the direction the
/// moment the script ends, so `TransitionCamera` never gets a turn and every
/// re-seat assertion below still reads the frame the warp left. The scroll
/// itself is graded by the movie rungs, where it happens for real.
const trans_dir_right: u8 = 0x01;
const trans_dir_down: u8 = 0x08;

/// One crossing the gate drives, and where the arm it selects draws.
///
/// **Both a horizontal and a vertical one, because D2 asks for it and because
/// the two arms are not the same shape.** Right, left and up draw three strips;
/// down draws four, since a downward crossing brings in one more row (00:$2A4F
/// against $2939, $29C4 and $2B04). A gate that only ever went sideways would
/// pass with the fourth strip missing and with the row arm never run at all.
const Crossing = struct {
    dir: u8,
    /// 1 walks a column downwards (00:$07E4), 0 walks a row rightwards ($0788).
    axis: u8,
    /// Each strip's start, as an offset from the camera the warp left.
    starts: []const [2]i32,
    name: []const u8,
};

const crossings = [_]Crossing{
    .{
        .dir = trans_dir_right,
        .axis = 1,
        // 00:$2951, $2989, $29B3, each with the Y of $2961.
        .starts = &.{ .{ 0x50, -0x74 }, .{ 0x60, -0x74 }, .{ 0x70, -0x74 } },
        .name = "rightward",
    },
    .{
        .dir = trans_dir_down,
        .axis = 0,
        // 00:$2A75, $2A9F, $2AC9, $2AF3, each with the X of $2A67.
        .starts = &.{ .{ -0x80, 0x78 }, .{ -0x80, 0x68 }, .{ -0x80, 0x58 }, .{ -0x80, 0x48 } },
        .name = "downward",
    },
};

/// One candidate cell for the incoming edge, expanded to Game Boy tile ids.
const ExpandedCell = struct { cell: u8, tiles: [1024]u8 };

/// The cells `WarpDraw`'s rightward arm can read, expanded through the table
/// the script selects.
///
/// **Baked as map data, not as an answer.** Which slots the strips write
/// depends on the camera at the moment of the warp, and the camera by then is
/// wherever seven phases of walking left it -- not the boot record's. So the
/// expansion is baked here, where the ROM is, and the *addressing* is done on
/// the emulator side against the camera it reads back. That split is
/// deliberate: the addressing is three shifts and is the thing being asserted,
/// while the expansion is the metatile table applied to a screen body, which is
/// exactly the kind of thing a Lua reimplementation would get wrong in the same
/// way the engine might.
///
/// The destination and its eight neighbours, which is everything either arm can
/// reach: a strip is 256 pixels long, so it spans two cells along its own axis
/// wherever it starts, and the set of strips reaches one cell either side
/// across it. A cell with no screen is left out, and the emulator side skips
/// those the way `StreamOne` does.
fn expandedCells(
    gpa: std.mem.Allocator,
    rom: []const u8,
    map_index: u8,
    row: u4,
    col: u4,
    tt: u4,
) ![]ExpandedCell {
    const bank = room.map_bank_first + map_index;
    var parsed = try map_mod.parseBank(gpa, rom, bank);
    defer parsed.deinit(gpa);

    var out: std.ArrayList(ExpandedCell) = .empty;
    errdefer out.deinit(gpa);
    for ([_]u4{ row -% 1, row, row +% 1 }) |r| {
        for ([_]u4{ col -% 1, col, col +% 1 }) |c| {
            const cell: u8 = (@as(u8, r) << 4) | @as(u8, c);
            const body = map_mod.screenBody(rom, bank, parsed.cells[cell].screen_ptr) orelse continue;
            const tiles = oracle.expandCell(rom, body, tt) orelse continue;
            try out.append(gpa, .{ .cell = cell, .tiles = tiles });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The button the engine reads as jump, by the name Mesen's `setInput` uses.
/// `engine/main.asm` puts jump on B, the way Super Metroid does.
const jump_button = "b";

/// And the one it reads as fire: `!PAD_FIRE` is `!PAD_Y`, the left face button,
/// which is where the rando's players expect it. Named here beside jump so a
/// remap is two lines rather than a search, and asserted against the engine's
/// own define by the test at the foot of this file.
const fire_button = "y";

/// The shape of every metasprite in Samus's set, as the gate needs to know it:
/// how many parts the walk should produce, and where the first one sits
/// relative to the anchor.
///
/// Baked from the converted blobs rather than recomputed in Lua on purpose. The
/// point of the check is that the engine's walk agrees with what the builder
/// put in the cart, and a Lua reimplementation of the walk would agree with the
/// engine's bugs as readily as with its correctness. This is the same argument
/// that made Step 13 bake the screen render instead of predicting the camera.
fn writeSprites(w: *std.Io.Writer, set: convert.Set) !void {
    const ptrs = set.metasprites[@intFromEnum(sprites.Which.samus_pointers)].bytes;
    const data = set.metasprites[@intFromEnum(sprites.Which.samus_data)].bytes;
    const n = ptrs.len / 2;

    try w.print("-- id -> part count, and the first part's offset from the anchor.\n", .{});
    try w.print("local SPR_PARTS, SPR_DY, SPR_DX, SPR_T0 = {{}}, {{}}, {{}}, {{}}\n", .{});
    for (0..n) |id| {
        const at = std.mem.readInt(u16, ptrs[id * 2 ..][0..2], .little);
        var pos: usize = at;
        var parts: usize = 0;
        while (pos < data.len and data[pos] != entity.terminator) : (pos += entity.part_bytes) parts += 1;
        // A record with no parts has no first part; the gate skips those, and
        // none of the ids the six reachable poses name is one.
        const dy: u8 = if (parts == 0) 0 else data[at];
        const dx: u8 = if (parts == 0) 0 else data[at + 1];
        const t0: u8 = if (parts == 0) 0 else data[at + 2];
        try w.print("SPR_PARTS[{d}], SPR_DY[{d}], SPR_DX[{d}], SPR_T0[{d}] = {d}, {d}, {d}, {d}\n", .{ id, id, id, id, parts, dy, dx, t0 });
    }
    try w.print("\n", .{});
}

fn writeScreen(w: *std.Io.Writer, name: []const u8, pixels: []const u8) !void {
    try w.print("local {s} = {{\n", .{name});
    for (0..screens.screen_px) |y| {
        try w.print("  \"", .{});
        for (0..screens.screen_px) |x| try w.print("{d}", .{pixels[y * screens.screen_px + x]});
        try w.print("\",\n", .{});
    }
    try w.print("}}\n\n", .{});
}

/// Phase 28's doors (Step 24): the Bomb's room and the Spider Ball's, both
/// carrying `ITEM`, which the recording collects. Two, so the second is graded
/// over characters the first has already written. A third joins them in Step
/// 24b, found rather than named: the first door whose script loads an enemy
/// sheet and does not fade, which is what 181 of the scrolling doors do.
const item_gfx_doors = [_]u16{ 0x145, 0x08D };

/// A scrolling door's script, frame for frame, is the room held still at the
/// Game Boy's `$93`, and `lit` says the phase may hold the cart to that. A
/// `FADEOUT` darkens on purpose, which is the `fade` rung's to grade, so a door
/// with one is refused here rather than graded against the wrong picture.
fn scrolls(ops: []const @import("door.zig").Op) bool {
    for (ops) |op| if (op == .fadeout) return false;
    return true;
}

/// A WRAM address the engine names with a define rather than a label, read
/// out of `engine/main.asm` the way `transition.zig` reads `!COPY_BG`.
/// Step 24e: every cell whose transition word has bit 11 set, as a Lua set
/// keyed `map_index * 256 + cell`. On those screens the Game Boy draws Samus
/// behind the background (00:$3ED5, 01:$4BA1), and on no others.
fn writeBehindCells(rom: []const u8, w: *std.Io.Writer) !void {
    const names = [_][]const u8{
        "map9_transition_indexes", "mapA_transition_indexes", "mapB_transition_indexes",
        "mapC_transition_indexes", "mapD_transition_indexes", "mapE_transition_indexes",
        "mapF_transition_indexes",
    };
    try w.print("-- The screens whose transition word has bit 11 (Step 24e).\nPRI_BEHIND = {{", .{});
    var n: usize = 0;
    for (names, 0..) |name, mi| {
        const e = offsets.find(name) orelse return error.MissingTransitionIndexes;
        const words = rom[e.romOffset()..e.romEnd()];
        for (0..256) |cell| {
            if (words[cell * 2 + 1] & 0x08 == 0) continue;
            try w.print(" [{d}] = true,", .{mi * 256 + cell});
            n += 1;
        }
    }
    if (n == 0) return error.MissingTransitionIndexes;
    try w.print(" }}\n", .{});
}

fn engineDefine(prefix: []const u8) !u16 {
    const src = @embedFile("engine_asm");
    const at = std.mem.indexOf(u8, src, prefix) orelse return error.DefineMissing;
    const rest = src[at + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, " ;\r\n") orelse rest.len;
    return std.fmt.parseInt(u16, rest[0..end], 16);
}

fn writeGfxDoor(gpa: std.mem.Allocator, w: *std.Io.Writer, di: usize, gb_dest: u16, gb: []const u8, name: ?[16]u8) !void {
    const chr = @import("snes_chr.zig");
    try w.print("  {{ door = {d}, oa = {d}, ba = {d}, obj = {{", .{
        di,
        @as(u32, try target.gbDestToObj(gb_dest)) * 2,
        @as(u32, (try target.gbDestToChar(gb_dest)).wordAddr()) * 2,
    });
    const obj = try chr.to4bpp(gpa, gb);
    defer gpa.free(obj);
    for (obj) |b| try w.print("{d},", .{b});
    try w.writeAll("}, bg = {");
    const bg = try chr.to2bpp(gpa, gb);
    defer gpa.free(bg);
    for (bg) |b| try w.print("{d},", .{b});
    try w.writeAll("}");
    // Step 24g: the window's second row after the script, when it has an
    // `ITEM`; a door without one leaves the row as the door before left it.
    if (name) |n| {
        try w.writeAll(", name = {");
        for (n) |b| try w.print("{d},", .{b});
        try w.writeAll("}");
    }
    try w.writeAll(" },\n");
}

/// One Game Boy 2bpp tile as a Lua string of shade digits through BGP, the way
/// the Game Boy shows a window tile.
fn writeShades(w: *std.Io.Writer, tile: []const u8) !void {
    try w.writeAll("\"");
    for (0..8) |row| {
        for (0..8) |col| {
            const bit: u3 = @intCast(7 - col);
            const c: u8 = ((tile[row * 2] >> bit) & 1) | (((tile[row * 2 + 1] >> bit) & 1) << 1);
            try w.print("{d}", .{(screens.live_bgp >> @intCast(c * 2)) & 3});
        }
    }
    try w.writeAll("\"");
}

/// `item_names[nib]`: the sixteen bytes `ITEM`'s fourth transfer copies to the
/// window's second row (00:$26A0-$26CB), through the pointer table the arm
/// indexes, so a table read one entry over is a different name.
fn itemName(rom: []const u8, nib: u4) ![16]u8 {
    const e = offsets.find("item_names") orelse return error.MissingTable;
    const table = rom[e.romOffset()..e.romEnd()];
    const ptr = std.mem.readInt(u16, table[@as(usize, nib) * 2 ..][0..2], .little);
    if (ptr < e.gb_addr or ptr + 16 > e.gb_addr + e.size) return error.MissingTable;
    return table[ptr - e.gb_addr ..][0..16].*;
}

/// Step 24g: the window's second row and where the window stands. `rWY` is
/// $88 or $80, the operands of `miscIngameTasks`' two writes (01:$580D and
/// $582A); the port's copy is `!WinY`. The row is `saveTextTilemap` at boot --
/// `loadTitleScreen`'s second copy, `LD HL,$4104 / LD DE,$9C20 / LD B,$14` at
/// 05:$40A0, read off those bytes -- and `item_names` after an `ITEM`. Its
/// glyphs are the item font, as `ITEM`'s third transfer leaves it.
fn writeBar(rom: []const u8, w: *std.Io.Writer) !void {
    const copy = rom[blocks_mod.offsetIn(5, 0x40A0)..][0..8];
    if (copy[0] != 0x21 or copy[3] != 0x11 or copy[6] != 0x06) return error.MissingTable;
    if (std.mem.readInt(u16, copy[4..6], .little) != 0x9C20) return error.MissingTable;
    const src = std.mem.readInt(u16, copy[1..3], .little);
    const text = rom[blocks_mod.offsetIn(5, src)..][0..copy[7]];
    try w.print("HUD.winY, HUD.wy, HUD.wyUp = {d}, {d}, {d}\nHUD.boot = {{", .{
        @as(u16, @truncate(inject.symbol("VarWinY") orelse return error.MissingSymbol)),
        try blocks_mod.loadAt(rom, 0x580D), try blocks_mod.loadAt(rom, 0x582A),
    });
    for (text) |b| try w.print("{d},", .{b});
    try w.print("}}\nHUD.font = {{\n", .{});
    const arm = convert.itemArm(rom) orelse return error.NoItemArm;
    const font = rom[blocks_mod.offsetIn(arm.font_bank, arm.font_src)..][0..arm.font_len];
    // $8C00 through the window's $8800 addressing and the objects' $8000 alike.
    const first: usize = 0xC0;
    if (arm.font_dest != 0x8000 + first * 16) return error.NoItemArm;
    for (0..font.len / 16) |i| {
        try w.print("  [{d}] = ", .{first + i});
        try writeShades(w, font[i * 16 ..][0..16]);
        try w.print(",\n", .{});
    }
    try w.print("}}\n", .{});
}

/// What the characters must hold after each of those doors' scripts, at both
/// depths. For `ITEM`, `$8B00`-`$8B7F`: the orb and the nibble's four tiles,
/// read out of the ROM through the arm `convert.itemArm` parses, with the
/// nibble taken from the door's own script. For the sheet, `LOAD`'s
/// `load_spr_len` bytes at `load_spr_dest`, from the door's own source. A
/// global table, since the main chunk is at Lua's 200-local limit.
fn writeItemGfx(gpa: std.mem.Allocator, rom: []const u8, w: *std.Io.Writer) !void {
    const door_mod = @import("door.zig");
    const arm = convert.itemArm(rom) orelse return error.NoItemArm;
    if (arm.orb_dest + arm.orb_len != arm.tile_dest) return error.NoItemArm;
    var decoded = try door_mod.decodeRegion(gpa, door_mod.region(rom).?);
    defer decoded.deinit(gpa);
    const ptrs = door_mod.pointers(rom).?;
    const bank_at = @as(usize, arm.bank) * offsets.bank_size;

    // 00:$0C2B, the end of a door's scroll: `LD A,($D07E) / CP $93 / RET Z /
    // LD A,$2F / LD ($D09B),A`. Phase 27 ends its scroll by clearing the
    // direction, which skips this, so phase 28 does it in its place -- the
    // palette and the timer from the ROM, and the two addresses from the
    // engine's defines, since they are not labels.
    const end_door = [_]?u8{ 0xFA, 0x7E, 0xD0, 0xFE, null, 0xC8, 0x3E, null, 0xEA, 0x9B, 0xD0 };
    for (end_door, rom[0x0C2B..][0..end_door.len]) |want, got| {
        if (want) |b| if (b != got) return error.NoEndDoorFade;
    }
    try w.print(
        \\-- The characters a door's transfers leave, phase 28 (Steps 24, 24b).
        \\ITEMGFX = {{ at = 1, st = {{}}, bgp = {d}, fin = {d}, normal = {d}, start = {d}, doors = {{
        \\
    , .{ try engineDefine("!BgPalette    = $"), try engineDefine("!FadeIn       = $"), rom[0x0C2F], rom[0x0C32] });
    for (item_gfx_doors) |di| {
        const ops = screens.scriptOps(decoded, ptrs, di) orelse return error.NoItemScript;
        if (!scrolls(ops)) return error.NoItemScript;
        var nib: ?u4 = null;
        for (ops) |op| if (op == .item) {
            nib = op.item;
        };
        // Zero is a save station's, which is not an item.
        const n = nib orelse return error.NoItemScript;
        if (n == 0) return error.NoItemScript;
        const tiles = arm.tile_base + (@as(u16, n) - 1) * arm.tile_len;
        const gb = try std.mem.concat(gpa, u8, &.{
            rom[bank_at + (arm.orb_src & 0x3FFF) ..][0..arm.orb_len],
            rom[bank_at + (tiles & 0x3FFF) ..][0..arm.tile_len],
        });
        defer gpa.free(gb);
        try writeGfxDoor(gpa, w, di, arm.orb_dest, gb, try itemName(rom, n));
    }
    const sheet: struct { di: usize, bank: u8, addr: u16 } = find: for (0..door_mod.pointer_count) |di| {
        const ops = screens.scriptOps(decoded, ptrs, di) orelse continue;
        if (!scrolls(ops)) continue;
        for (ops) |op| switch (op) {
            .load => |l| if (l.which == .spr) break :find .{ .di = di, .bank = l.src_bank, .addr = l.src_addr },
            else => {},
        };
    } else return error.NoSheetDoor;
    const src = @as(usize, sheet.bank) * offsets.bank_size + (sheet.addr & 0x3FFF);
    try writeGfxDoor(gpa, w, sheet.di, screens.load_spr_dest, rom[src..][0..screens.load_spr_len], null);
    // Step 24g: a save room's door, found as the sheet door is: the first that
    // does not fade and runs `ITEM $D0` after its last object `LOAD`, since a
    // sheet loaded after it would overwrite the font at $8C00 on the Game Boy
    // too. Last, so the station phase 28 then lays stands under its " SAVE<>"
    // with the font resident. Nibble 0 reads the sixteenth tile window.
    const save_di: usize = find: for (0..door_mod.pointer_count) |di| {
        const ops = screens.scriptOps(decoded, ptrs, di) orelse continue;
        if (!scrolls(ops)) continue;
        var item_at: ?usize = null;
        var sheet_at: ?usize = null;
        for (ops, 0..) |op, i| switch (op) {
            .item => |n| if (n == 0) {
                item_at = i;
            },
            .load => |l| if (l.which == .spr) {
                sheet_at = i;
            },
            else => {},
        };
        const at = item_at orelse continue;
        if (sheet_at) |sa| if (sa > at) continue;
        break :find di;
    } else return error.NoSaveDoor;
    {
        const tiles = arm.tile_base + @as(u16, convert.item_nibbles - 1) * arm.tile_len;
        const gb = try std.mem.concat(gpa, u8, &.{
            rom[bank_at + (arm.orb_src & 0x3FFF) ..][0..arm.orb_len],
            rom[bank_at + (tiles & 0x3FFF) ..][0..arm.tile_len],
        });
        defer gpa.free(gb);
        try writeGfxDoor(gpa, w, save_di, arm.orb_dest, gb, try itemName(rom, 0));
    }
    try w.writeAll("} }\n");
}

pub fn write(gpa: std.mem.Allocator, rom: []const u8, set: convert.Set, boot: screen.Boot, w: *std.Io.Writer) !void {
    const plan = try planFor(set, boot);
    // The boot record's own door is the one the cart is made to run in phase 8.
    // It has to have a warp in it, and every door that leads anywhere does --
    // but the refusal is here rather than a silent skip, because a gate that
    // quietly stops testing the transition is exactly the failure this phase
    // was added to prevent.
    const warp = warpTarget(set, boot) orelse return error.BootDoorDoesNotWarp;

    // How many frames the Game Boy's interpreter would spend on that same
    // script, from `src/transition.zig`'s rule -- which is graded against a
    // running Game Boy opcode for opcode, so this number is the original's and
    // not the port's own arithmetic played back at it.
    //
    // `$D089` is zero here rather than the run's Metroid count: the lever this
    // phase pulls writes only the door index, so no `IF_MET_LESS` can be taken
    // and the count cannot matter.
    //
    // **The direction is not zero any more.** It was, until Step 6, and zero is
    // 00:$2938 -- the arm a direction the compare chain does not recognise
    // falls through to, which draws nothing and waits for nothing. The phase
    // drives a real direction now so the incoming edge is actually drawn, and
    // `scriptFrames` is asked for that direction's cost so the duration
    // assertion below still holds to the frame.
    const script = try transition.script(rom, boot.door_index, 0);

    // The table the script leaves in force, which is what the incoming edge is
    // drawn through. A script that selects none inherits the record's, exactly
    // as `StartDoorScript` does.
    var strip_table: u4 = boot.tiletable;
    for (script.ops[0..script.count]) |op| switch (op) {
        .tiletable => |v| strip_table = v,
        else => {},
    };
    const expanded = try expandedCells(gpa, rom, warp.bank, warp.row, warp.col, strip_table);
    defer gpa.free(expanded);

    const here = try render.screenAt(gpa, set, boot, boot.cell);
    defer gpa.free(here);
    // The screen the camera walks into. It is drawn from the neighbour's body
    // alone, so if the window cut out of it matches on the emulator then the
    // streamer rebuilt the whole tilemap out of that screen without `LoadScreen`
    // ever running again - which is the thing Step 12a added.
    const after = try render.screenAt(gpa, set, boot, plan.after_open);
    defer gpa.free(after);

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- Exit codes:
        \\--   0  the cart drew the right screens, and Samus and the camera obeyed them
        \\--  10  Fatal ran: the engine could not find something it was patched to find
        \\--  11  the frame counter never advanced: boot never finished
        \\--  12  no character data reached VRAM
        \\--  13  the tilemap was never uploaded
        \\--  14  the boot record's cell was not seeded into the engine's state
        \\--  15  the palette in CGRAM is not the one the builder patched in
        \\--  16  the frame counter's phase: NMI ran a different number of times
        \\--      between the boot record's seed and the first frame of MainLoop
        \\--  17  the play window straddled two screens where a picture was compared
        \\--  18  the camera never reached the guide it holds her at, or drifted off it
        \\--  19  the jump arc never ran, or lifted her no higher than the linear part
        \\--  20+ the play window differs; the code is 20 + (row / 8), capped at 60
        \\--  61  Samus never came to rest after the fall she starts in
        \\--  62  Samus fell out of the screen she starts on
        \\--  63  pressing jump never lifted her, or she never came back down
        \\--  64  the jump skipped the poses a jump goes through
        \\--  65  the jump did not put her back on the row it started from
        \\--  66  a frame moved her sideways by more than a walk step
        \\--  67  two frames moved her sideways by more than three pixels
        \\--  68  the camera did not follow her up the jump
        \\--  69  walking into the blocked edge neither stopped her nor reached the clamp
        \\--  79  the camera was showing a window Samus was not standing in
        \\--  70  the camera passed the clamp on the edge the screen blocks
        \\--  71  the camera changed screens across the edge the screen blocks
        \\--  72  walking into an opening never crossed into the neighbour
        \\--  73  the camera crossed into the wrong cell
        \\--  74  the camera jumped: a frame moved it further than a walk can
        \\--  75  the camera never came to rest inside the neighbour
        \\--  76  a held direction did not read as held every frame
        \\--  77  a held direction rose more than once, or never rose at all
        \\--  78  the engine was handed a pose it could not run
        \\--  80+ the neighbour differs after walking in; 80 + (row / 8), capped at 120
        \\-- 121  nothing was composed into OAM: Samus was not drawn at all
        \\-- 122  her sprite's anchor is not the camera guide with the biases exchanged
        \\-- 123  the metasprite walk produced the wrong number of parts for the id
        \\-- 124  her OAM entry is not the anchor with the window offsets on it
        \\--  20  her OAM priority is not what her screen's transition word says:
        \\--      0 (behind) where bit 11 is set, 2 (in front) elsewhere
        \\-- 125  the sprite id did not change between standing and jumping
        \\-- 126  the sprite id did not change when she turned round
        \\-- 127  she covered an implausible amount of the window, or none of it
        \\-- 130  the door script never ran: !DoorIndex was still set
        \\-- 131  the warp did not change the map index to the one the script names
        \\-- 132  the warp did not put her in the cell the script names
        \\-- 133  the camera's screen halves are not the warp's
        \\-- 134  Samus's screen halves are not the warp's
        \\-- 135  a pixel half moved: the warp replaced more than the screen
        \\-- 137  the incoming edge is not the room the warp arrived in
        \\-- 140  the pickup never started: `!ItemStage` stayed idle
        \\-- 141  the item bit did not land four frames after the freeze began
        \\-- 142  the wrong bit was set, or more than one
        \\-- 143  Samus moved while the jingle was playing
        \\-- 144  the jingle was shorter than the Game Boy's $0160 frames
        \\-- 145  the pickup never ended: `!ItemStage` never returned to idle
        \\-- 146  the ball jump never fired with Spring Ball held
        \\-- 147  the ball jump fired with `!Items` cleared: the branch is not gated
        \\-- 148  the ball jump fired with only the Bomb: 00:$1727 tests Spring Ball
        \\-- 138  after a door's `ITEM` or `LOAD_spr`, the characters are not the ROM's
        \\-- 139  that check could not be made: the script never finished, or the
        \\--      characters already held the answer before it ran
        \\-- 128  a door script with no `FADEOUT` ended a frame blanked or dimmed
        \\-- 129  ...or blacked out a window row that was lit before the trigger
        \\-- 150  `!SolidBeam` is not the beam threshold the boot door's tileset carries
        \\-- 151  the block was still solid after its counter passed the empty frame
        \\-- 152  a crack frame did not land on the counter the cartridge names
        \\-- 153  destroying the floor under Samus did not stop her standing
        \\-- 154  the block never reformed: the four tiles did not come back
        \\-- 155  the slot was not freed when the block reformed
        \\-- 156  Samus did not stand again on the floor that came back
        \\-- 157  an off-camera block was not evicted, or drew a picture on its way out
        \\-- 158  the reform's crush branch fired, and 01:$5790 is only recorded
        \\-- 185  a bomb was laid without the Bomb
        \\-- 186  the ball never came to rest, or the fire button laid no bomb
        \\-- 187  the bomb has the wrong type or is not where 01:$5400 lays it
        \\-- 188  one press laid more than one bomb
        \\-- 189  the bomb was not drawn first, where its slot says it is
        \\-- 191  the fuse or the explosion is not the length the cartridge loads
        \\-- 192  the bomb-only block beside the explosion did not go
        \\-- 193  the respawning block at the explosion's right tile was not reached
        \\-- 194  Samus was not thrown into `samus_bombPoseTable`'s pose
        \\-- 195  the enemy beside the explosion took nothing, or the wrong amount
        \\-- 196  the explosion did not end, or ended early
        \\-- 197  the cart did not boot with the new game's loadout
        \\-- 198  Select did not switch to missiles, or back
        \\-- 199  the cannon's tiles in VRAM are not the sheet the toggle asked for
        \\-- 200  the toggle did not split the pass across a frame, or never resumed it
        \\-- 201  the fire button with missiles selected launched no missile
        \\-- 202  a missile did not cost exactly one, in BCD
        \\-- 203  with no missiles left the fire button launched one, or no dud
        \\-- 204  a pixel of the status bar is not the window tile BG2 names there
        \\-- 205  the HUD icon is not in OAM where `drawHudMetroid` puts it
        \\-- 206  the HUD icon's frame is not `frameCounter` bit 4's
        \\-- 207  the HUD icon did not rise for a major item or a save station, or rose without either
        \\-- 208  the displayed health did not roll one unit a frame to the real one
        \\-- 209  the roll asked for no tick sound on a fourth frame, or asked off one
        \\--   1  `!WinY` is not `rWY`'s: $80 for a station or a major item's jingle, else $88
        \\--   2  the status bar was not a row higher on the screen while the window was up
        \\--   3  the window's second row is not `saveTextTilemap` or the door's `item_names` entry
        \\--   4  the bar's pixels are not the item font's, or phase 28's station never raised it
        \\-- 210  Samus moved while a Metroid was appearing, or not once it was over
        \\-- 211  the cutscene left her in a turnaround
        \\-- 212  a held pad changed her sprite while the pad was not being read
        \\-- 213  Select did not toggle during the cutscene, or resumed the Samus block
        \\-- 214  the Alpha's coin is not `!EnFrame`'s low bit, or no hurt landed
        \\-- 215  the Alpha's coin came up the same way on every hurt
        \\-- 216  the last missile did not kill: no `$80`, no fight flag 2, no explosion, no jingle
        \\-- 217  a count did not fall by one in BCD, or no shuffle, or `earthquakeCheck` was not reached
        \\-- 218  the explosion did not freeze Samus, step its six frames four times, and free the slot
        \\-- 219  the post-death timer stepped on an odd frame, or not once a frame pair, or not to $90
        \\-- 220  the restore did not ask for the room's song, or asked with no Metroids left
        \\-- 221  the restore did not end the fight, or the HUD's count is not one lower
        \\-- 222  a transition mid-fight did not ask for the room's song, or one with no fight did
        \\-- 227  a gate door's incoming edge is not its room drawn through the table the ROM's pointer names
        \\-- 251  standing on acid did not latch `acidContactFlag`, or the table has no solid acid tile
        \\-- 252  standing on solid acid did not lose exactly one damage on each $x0 frame, and nothing on the others
        \\-- 253  Samus was drawn on an acid frame whose counter's bit 2 is clear (01:$4BE8)
        \\-- 149  Samus was drawn on OBP0 in acid or i-frames, or on OBP1 out of them (01:$4DFC, $4B95)
        \\-- 254  falling into liquid acid did not lose 4 on the first tick, or standing after it not 2
        \\-- 233  Down in the ball entered the spider without Spider Ball, or the ball never came to rest
        \\-- 234  Down in the ball with Spider Ball held did not enter the spider ball
        \\-- 235  the spider ball at rest on a floor does not read both bottom corners, and only them
        \\-- 236  the spider ball did not roll a pixel a frame on one axis, or did not roll at all
        \\-- 237  releasing the pad did not stop the roll, or A did not leave the spider for the ball
        \\-- 238  a falling or jumping spider ball landing on the floor did not attach to it
        \\-- 239  Down in the bombed ball with Spider Ball held did not enter the spider (00:$0ECB)
        \\-- 240  standing on a save station's tile did not set the contact (00:$1F4F)
        \\-- 241  Start on a station did not take the save on the next frame, alone, with the cooldown at $FF
        \\-- 242  the record in cartridge RAM is not the magic and `save.fields` from the live state
        \\-- 243  the spawn flags were not saved as $02 and $FE kept, $04 made $FE, and $05 left out
        \\-- 244  a second Start while "COMPLETED" showed saved again (01:$582E)
        \\-- 245  the contact was not cleared by the cooldown running out off the station, or by a door
        \\-- 249  the sound engine never ran `init`, or ran no ticks (a smoke check, not a grade)
        \\-- 159  a crossing's camera frame did not add 1 to the spin timer and 3 to the run cycle's
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local cgram = emu.memType.snesCgRam
        \\
        \\local RAM_FRAMES, RAM_CELL = {d}, {d}
        \\local RAM_CAMX, RAM_CAMY = {d}, {d}
        \\local RAM_HELD, RAM_EDGE = {d}, {d}
        \\local RAM_SAMX, RAM_SAMY = {d}, {d}
        \\local RAM_POSE, RAM_UNHANDLED = {d}, {d}
        \\local RAM_JUMPARC, JUMP_BASE = {d}, {d}
        \\local POSE_STAND, POSE_JUMP, POSE_FALL, POSE_NJUMPSTART = {d}, {d}, {d}, {d}
        \\local WALL_BIT, OPEN_BIT = {d}, {d}
        \\local WALL_DIR, OPEN_DIR, JUMP_BTN = "{s}", "{s}", "{s}"
        \\local VIEW_W, VIEW_H, SCREEN_PX = {d}, {d}, {d}
        \\local WIN_LEFT, BAND_TOP = {d}, {d}
        \\local CELL, CELL_AFTER_OPEN = {d}, {d}
        \\local PALETTE = {{ {d}, {d}, {d}, {d} }}
        \\
    , .{
        screen.ram.frame_count,      screen.ram.cell,
        screen.ram.cam_x,            screen.ram.cam_y,
        screen.ram.input_pressed,    screen.ram.input_rising_edge,
        screen.ram.samus_x,          screen.ram.samus_y,
        screen.ram.pose,             screen.ram.unhandled,
        screen.ram.jump_arc,         physics.jump_array_base_offset,
        screen.pose.stand,           screen.pose.jump,
        screen.pose.fall,            screen.pose.njump_start,
        screen.padBit(plan.wall),    screen.padBit(plan.open),
        @tagName(plan.wall),         @tagName(plan.open),
        jump_button,
        target.view_w,               target.view_h,
        screens.screen_px,
        screen.win_left,             screen.band_top,
        boot.cell,                   plan.after_open,
        boot.palette[0],             boot.palette[1],
        boot.palette[2],             boot.palette[3],
    });

    // The bit the *cartridge's* Bomb arm sets, read out of its `SET n,A` rather
    // than taken from the engine's own mask. Taking it from the engine would
    // make the check vacuous, and taking it from M2RoS's constants file would
    // have agreed with the bug this found: see `docs/bug_tracker.md`,
    // 2026-09-09.
    const item_bit = (try items_mod.bitFor(rom, .bomb)) orelse return error.ItemSetsNoBit;
    const item_mask: u8 = @as(u8, 1) << item_bit;
    // And Spring Ball's, the same way, which is the bit 00:$1727's `BIT 4,A`
    // gates the ball's A jump on (Step 24; phase 10 had it as the Bomb's).
    const spring_bit = (try items_mod.bitFor(rom, .spring_ball)) orelse return error.ItemSetsNoBit;
    const spring_mask: u8 = @as(u8, 1) << spring_bit;

    // Its own `print` because the one above is already at Zig's ceiling of
    // thirty-two format arguments, and the thirty-third is what B4b needed.
    try w.print(
        \\local RAM_FRAMEPHASE = {d}
        \\-- The item pickup, phase 9. ITEM_NUMBER is the Bomb, and ITEM_MASK is
        \\-- the bit the *cartridge's* own pickup arm sets for it - read out of
        \\-- the `SET n,A` opcode at 00:$3845 by `items.bitFor`, not copied from
        \\-- a constants file. Two of the engine's six masks were wrong when
        \\-- this was written, and a mask taken from the same place the engine
        \\-- took its would have agreed with the bug.
        \\local RAM_ITEMS, RAM_ITEMCOLLECTED, RAM_ITEMSTAGE = {d}, {d}, {d}
        \\local RAM_ITEMFLAG = {d}
        \\local ITEM_NUMBER, ITEM_MASK, ITEM_WAIT, ITEM_JINGLE = {d}, {d}, {d}, {d}
        \\local POSE_MORPH, POSE_BALLJUMP, BOMB_TRY = {d}, {d}, {d}
        \\local POSE_BALLFALL = {d}
        \\local RAM_DOWNSPEED = {d}
        \\-- A global, not a local: the main chunk is at Lua's 200-local limit.
        \\SPRING_MASK = {d}
        \\
    , .{
        screen.ram.frame_phase,
        screen.ram.items,        screen.ram.item_collected,
        screen.ram.item_stage,    screen.ram.item_flag,
        @intFromEnum(items_mod.Collected.bomb),
        item_mask,
        item_wait_frames,        item_jingle_frames,
        screen.pose.morph,       screen.pose.ball_jump,
        bomb_try_frames,         screen.pose.ball_fall,
        screen.ram.down_speed,   spring_mask,
    });
    try writeItemGfx(gpa, rom, w);

    // The transition's own constants, in a print of their own: the preamble
    // above is already at the formatter's limit of 32 arguments.
    try w.print(
        \\-- The room transition, phase 8.
        \\local RAM_MAPIDX, RAM_DOORIDX = {d}, {d}
        \\local RAM_TRANSDIR, RAM_TILEMAP = {d}, {d}
        \\local DOOR_INDEX, WARP_BANK, WARP_ROW, WARP_COL = {d}, {d}, {d}, {d}
        \\
    , .{
        screen.ram.map_index, screen.ram.door_index,
        screen.ram.trans_dir, screen.ram.tilemap_buf,
        boot.door_index,      warp.bank,
        warp.row,             warp.col,
    });
    try writeBehindCells(rom, w);

    // B5's terrain half, phases 11 and 12. Every number here is read out of the
    // cartridge by `src/blocks.zig` rather than copied from `engine/main.asm` --
    // the gate and the engine must not share a source for a constant the gate
    // is grading, which is the lesson the title-screen expectation cost.
    //
    // `BEAM_THRESHOLD` is the strongest of them: the tileset comes from the
    // boot door's own `SOLIDITY` operand, the column from the ROM's store
    // sequence at 00:$2446, and the byte from the table at 8:$7EFA. Nothing in
    // the engine takes part in producing it.
    const solidity_op = blocks_mod.solidityOf(script.ops[0..script.count]) orelse
        return error.BootDoorSetsNoSolidity;
    const beam_threshold = try blocks_mod.beamThresholdFor(rom, solidity_op);
    const probe_y: u16 = physics.oam_y_ofs +
        @as(u16, @truncate(inject.symbol("ConstOriginYBottom") orelse return error.MissingSymbol));
    const probe_x: u16 = physics.oam_x_ofs +
        @as(u16, @truncate(inject.symbol("ConstOriginXLeft") orelse return error.MissingSymbol)) + 1;

    try w.print(
        \\-- The destructible blocks, phases 11 and 12.
        \\local RAM_BLOCKS, BLK_SIZE = {d}, {d}
        \\local RAM_SOLIDBEAM, RAM_BLKCRUSH = {d}, {d}
        \\local BEAM_THRESHOLD = {d}
        \\-- `CollideBottom`'s own foot probe, which is where the block under her
        \\-- is: 00:$1F13's `OAM + originXLeft + 1` and `OAM + originYBottom`.
        \\local PROBE_X, PROBE_Y = {d}, {d}
        \\-- The counters `handleRespawningBlocks` dispatches on, out of its six
        \\-- `CP d8` at 01:$56BC and after.
        \\local BLK_CRACK1, BLK_CRACK2, BLK_EMPTY_AT = {d}, {d}, {d}
        \\local BLK_CRACK3, BLK_CRACK4, BLK_REFORM = {d}, {d}, {d}
        \\-- And the tile ids the three drawing arms write, out of their `LD A,d8`.
        \\local BLK_TILE_SOLID, BLK_TILE_A = {d}, {d}
        \\local BLK_TILE_B, BLK_TILE_GONE = {d}, {d}
        \\local BLK_EVICT_Y, GB_SCROLL_Y_BIAS = {d}, {d}
        \\
    , .{
        screen.ram.blocks,        screen.ram.block_size,
        screen.ram.solid_beam,    screen.ram.blk_crush,
        beam_threshold,
        probe_x,                  probe_y,
        try blocks_mod.compareAt(rom, blocks_mod.counter_sites[0]),
        try blocks_mod.compareAt(rom, blocks_mod.counter_sites[1]),
        try blocks_mod.compareAt(rom, blocks_mod.counter_sites[2]),
        try blocks_mod.compareAt(rom, blocks_mod.counter_sites[3]),
        try blocks_mod.compareAt(rom, blocks_mod.counter_sites[4]),
        try blocks_mod.compareAt(rom, blocks_mod.counter_sites[5]),
        try blocks_mod.solidTile(rom),
        try blocks_mod.loadAt(rom, blocks_mod.tile_crack_a_site),
        try blocks_mod.loadAt(rom, blocks_mod.tile_crack_b_site),
        try blocks_mod.loadAt(rom, blocks_mod.tile_gone_site),
        try blocks_mod.compareAt(rom, blocks_mod.evict_sites[0]),
        try blocks_mod.subAt(rom, blocks_mod.scroll_y_bias_site),
    });

    // B5's projectile half, phases 13 and 14.
    //
    // Every number here is the cartridge's. The weapon's damage comes out of
    // the table at 02:$43C8, the stun a survivor takes out of the `LD A,d8` at
    // 02:$4333, the beam's speed out of the `ADD A,d8` at 01:$521E -- and the
    // enemy the shot is fired at is *found* rather than named: `targetEnemy`
    // takes the lowest id the cartridge gives a nonzero damage value and a
    // hitbox record that lands inside the hitbox blob, and returns the offsets
    // that put the box's centre on the projectile's point. Naming an id here
    // would be a number typed into the gate; finding one is a question the ROM
    // answers.
    const shot_at = try targetEnemy(rom);
    // `weapon_damage`'s first entry: what a power beam takes off an enemy. Out
    // of the converted blob rather than out of the engine, and **not** out of
    // `enemy_damage`, which is the damage an enemy does to *Samus* -- the two
    // tables are one byte per id and easy to confuse, which is why this is
    // named where it is read.
    const wd = offsets.find("weapon_damage") orelse return error.MissingWeaponDamage;
    const weapon_damage_0 = rom[wd.romOffset()];
    try w.print(
        \\-- B5's projectiles, phases 13 and 14.
        \\-- **One table and not thirty-five locals**, which is a Lua limit and
        \\-- not a style: a chunk may declare 200 of them and this file was at
        \\-- 198 before Step 12b. Written out flat, this block took it past the
        \\-- limit and the script stopped *parsing* -- so Mesen registered no
        \\-- callbacks, reached no verdict, and the gate reported a timeout
        \\-- that read exactly like a hung cart. Every group added from here on
        \\-- belongs in a table for that reason.
        \\local B5 = {{
        \\  projs = {d}, size = {d}, count = {d}, none = {d},
        \\  slots = {d}, slotSize = {d}, enTotal = {d}, enActive = {d},
        \\  status = {d}, y = {d}, x = {d}, sprite = {d},
        \\  baseattr = {d}, attr = {d}, stun = {d}, dirflags = {d}, ice = {d},
        \\  health = {d}, drop = {d}, explode = {d}, maxhp = {d}, flag = {d},
        \\  collWeapon = {d}, collEnemy = {d}, unhandled = {d},
        \\  -- The byte `HandleCamera`'s door triggers read, and Samus's
        \\  -- on-screen Y. Taken from the engine's own symbols rather than
        \\  -- mirrored here, because what is being asserted is *which*
        \\  -- variable the trigger reads -- and a mirror would agree with the
        \\  -- engine whichever one that was.
        \\  triggerX = {d}, onscreenY = {d}, hiddenY = {d},
    , .{
        screen.ram.projs,      screen.ram.proj_size,
        screen.ram.proj_count, screen.ram.proj_none,
        screen.ram.slots,      screen.ram.slot_size,
        screen.ram.en_total,   screen.ram.en_active,
        screen.ram.en_status,  screen.ram.en_ypos,
        screen.ram.en_xpos,    screen.ram.en_sprite,
        screen.ram.en_baseattr, screen.ram.en_attr,
        screen.ram.en_stun,
        screen.ram.en_dirflags,
        screen.ram.en_ice,
        screen.ram.en_health,  screen.ram.en_drop,
        screen.ram.en_explode, screen.ram.en_maxhp,
        screen.ram.en_flag,
        screen.ram.coll_weapon, screen.ram.coll_enemy,
        screen.ram.pr_unhandled,
        @as(u16, @truncate(inject.symbol("VarTriggerX") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarOnscreenY") orelse return error.MissingSymbol)),
        @as(u8, @truncate(inject.symbol("ConstOamHiddenY") orelse return error.MissingSymbol)),
    });
    // The formatter takes 32 arguments and the table wants more, so the rest of
    // it is a second print into the same braces.
    try w.print(
        \\  fire = "{s}", scrollXBias = {d},
        \\  -- The enemy the ROM chose, and where to put it so the shot lands
        \\  -- in the middle of the box its own hitbox record resolves to.
        \\  testId = {d}, dy = {d}, dx = {d},
        \\  -- 02:$43C8's first entry, the power beam's, and 02:$4333's stun.
        \\  dmg = {d}, stunHit = {d},
        \\  -- 01:$521E's `ADD A,d8`, and the bias the shot's collision point
        \\  -- carries over its drawn position (01:$528D).
        \\  beamSpd = {d}, hitBias = {d},
        \\  -- The slot's own four fields.
        \\  tType = 0, tDir = 1, tY = 2, tX = 3,
        \\  -- Phase 27's two animation timers, `$D022` and `$D072` on the Game
        \\  -- Boy, and the pose whose drawing clamps the first.
        \\  animT = {d}, spinT = {d}, poseRun = {d},
        \\}}
        \\
    , .{
        fire_button,
        try blocks_mod.subAt(rom, blocks_mod.scroll_x_bias_site),
        shot_at.id,            shot_at.dy,
        shot_at.dx,
        weapon_damage_0,       try blocks_mod.loadIn(rom, 2, 0x4333),
        try blocks_mod.addAt(rom, 0x521E),
        try blocks_mod.addAt(rom, 0x528D),
        @as(u16, @truncate(inject.symbol("VarAnimTimer") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSpinTimer") orelse return error.MissingSymbol)),
        @as(u8, @truncate(inject.symbol("ConstPoseRun") orelse return error.MissingSymbol)),
    });

    // B4c's first half, phases 16 and 17. A table for the reason `B5` is one,
    // and every number in it comes out of `engine.sym` rather than being
    // mirrored here -- which is what makes the chain complete: `correspond.zig`
    // grades the engine's constants against the opcodes the cartridge carries
    // them in, and this grades the running cart against the same constants. A
    // mirror would agree with the engine whatever the engine said.
    try w.print(
        \\local B4c = {{
        \\  -- The flag's bit and the two progressions it chooses between.
        \\  expBig = {d}, sprExpBig = {d}, sprExpNorm = {d},
        \\  expBigN = {d}, expN = {d}, expShort = {d},
        \\  -- The initial health that revives instead of dying, and the one that
        \\  -- is invulnerable -- which is also a corpse the cartridge never gives
        \\  -- a drop to, and that is why phase 16 uses it.
        \\  hpRespawn = {d}, hpInvuln = {d},
        \\  -- The three drops, each a type and the sprite that wears it.
        \\  dropSmall = {d}, sprDropSmall = {d},
        \\  dropLarge = {d}, sprDropLarge = {d},
        \\  dropMissile = {d}, sprDropMissile = {d},
        \\  -- How long a drop waits and how fast it blinks while it does.
        \\  dropLife = {d}, dropFast = {d}, dropSlowM = {d},
        \\  dropFastM = {d}, dropBlink = {d},
        \\  -- The slot's counter, which is the explosion's whole clock, and the
        \\  -- recorder two of `EnemyCommonAI`'s four state arms still use.
        \\  counter = {d}, unhandled = {d}, number = {d},
        \\  -- The pass's own counter, which `.becomeDrop`'s substituted roll
        \\  -- divides, and the flag that says which frames the pass acted on.
        \\  enFrame = {d}, enSame = {d},
        \\  -- Samus's health, BCD, low byte first.
        \\  healthLo = {d}, healthHi = {d},
        \\  -- `!FLAG_DEAD`. Not a pinned constant: 02:$56BC and 02:$5724 both
        \\  -- write it as a bare immediate and so does `EnemyDamageOrDrop`.
        \\  flagDead = 2,
        \\}}
        \\
    , .{
        try symByte("ConstEnExpBig"),       try symByte("ConstSprExpBig"),
        try symByte("ConstSprExpNorm"),     try symByte("ConstEnExpBigN"),
        try symByte("ConstEnExpN"),         try symByte("ConstEnExpShort"),
        try symByte("ConstEnHpRespawn"),    try symByte("ConstEnHpInvuln"),
        try symByte("ConstEnDropSmall"),    try symByte("ConstSprDropSmall"),
        try symByte("ConstEnDropLarge"),    try symByte("ConstSprDropLarge"),
        try symByte("ConstEnDropMissile"),  try symByte("ConstSprDropMissile"),
        try symByte("ConstEnDropLife"),     try symByte("ConstEnDropFast"),
        try symByte("ConstEnDropSlowM"),    try symByte("ConstEnDropFastM"),
        try symByte("ConstEnDropBlink"),
        screen.ram.en_counter,              screen.ram.en_unhandled_state,
        screen.ram.en_number,                screen.ram.en_frame,
        screen.ram.en_same,
        screen.ram.health_lo,               screen.ram.health_hi,
    });

    // B5's bombs, phase 18. The array's address and stride are layout and come
    // out of `engine.sym`; every number the phase *grades* is read out of the
    // cartridge -- the fuse, the explosion's length, where the bomb is laid, the
    // pose Samus is thrown into, the tile a bomb breaks and the damage it does.
    // `src/correspond.zig` grades the engine's copies of the same numbers
    // against the same opcodes, so the two meet at the ROM and nowhere else.
    const bomb_tile = try bombTile(rom, script.ops[0..script.count]);
    const bomb_at = try bombTarget(rom);
    try w.print(
        \\local BM = {{
        \\  bombs = {d}, size = {d}, count = {d}, none = {d},
        \\  -- 01:$53F8 and $53FB, the type and fuse a laid bomb gets; 01:$54C2 and
        \\  -- $54C5, what the fuse running out turns it into.
        \\  live = {d}, fuse = {d}, blast = {d}, blastN = {d},
        \\  -- 01:$5400 and $5405: where, from Samus's own position.
        \\  layY = {d}, layX = {d},
        \\  -- 01:$5528: how far the explosion's four outer tiles are from it.
        \\  probe = {d},
        \\  -- A tile id in the boot room's own collision table with the bomb
        \\  -- bit and not the shot bit, and `samus_bombPoseTable`'s entry for
        \\  -- the ball.
        \\  tile = {d}, hitPose = {d},
        \\  -- An enemy that does no damage to Samus, so a bomb reaches it where
        \\  -- a beam would not; the offsets that centre its box on a point, and
        \\  -- its half-extents. `weapon_damage`'s last entry is what it loses.
        \\  enId = {d}, enDy = {d}, enDx = {d}, enH = {d}, enW = {d}, dmg = {d},
        \\  pad = {d},
        \\  -- The Bomb's bit, and 01:$5454's first bomb frame.
        \\  itemMask = {d}, sprBomb = {d},
        \\}}
        \\
    , .{
        @as(u16, @truncate(inject.symbol("VarBombs") orelse return error.MissingSymbol)),
        try symByte("ConstBombSize"),
        try blocks_mod.compareAt(rom, 0x5497),
        try blocks_mod.compareAt(rom, 0x53E8),
        try blocks_mod.loadAt(rom, 0x53F8),
        try blocks_mod.loadAt(rom, 0x53FB),
        try blocks_mod.loadAt(rom, 0x54C2),
        try blocks_mod.loadAt(rom, 0x54C5),
        try blocks_mod.addAt(rom, 0x5400),
        try blocks_mod.addAt(rom, 0x5405),
        try blocks_mod.subAt(rom, 0x5528),
        bomb_tile,
        try bombHitPose(rom, screen.pose.morph),
        bomb_at.id,                    bomb_at.dy,
        bomb_at.dx,                    bomb_at.h,
        bomb_at.w,                     rom[wd.romOffset() + weapon_bomb],
        try blocks_mod.subIn(rom, 0, 0x3120),
        item_mask,
        try blocks_mod.addAt(rom, 0x5454),
    });

    // Step 13a, phase 19: missiles. The loadout the cart must boot with is the
    // ROM's `initialSaveFile`; the weapon id, the two sound requests and the
    // cannon's converted tiles are the cartridge's too.
    const loadout = screen.Loadout.newGame(rom) orelse return error.NoInitialSave;
    const cannon = struct {
        fn bytesOf(s: convert.Set, name: []const u8) ![]const u8 {
            for (s.assets) |a| {
                if (a.kind == .chr_obj and std.mem.eql(u8, a.name, name)) return a.bytes;
            }
            return error.NoCannonSheet;
        }
    };
    try w.print(
        \\local MS = {{
        \\  cur = {d}, max = {d}, health = {d}, tanks = {d}, metReal = {d}, metDisp = {d},
        \\  weapon = {d}, beam = {d}, hold = {d}, sfx1 = {d},
        \\  -- `initialSaveFile`, through `save.initial`.
        \\  wantCur = {d}, wantMax = {d}, wantHealth = {d}, wantTanks = {d},
        \\  wantReal = {d}, wantDisp = {d},
        \\  -- Version 15 (Step 22): the damage values, $D077 and $D078.
        \\  acid = {d}, spike = {d}, wantAcid = {d}, wantSpike = {d},
        \\  -- 00:$2215's `CP $08`, 00:$2225's select sound and 01:$4F2C's dud.
        \\  missile = {d}, sfxSelect = {d}, sfxDud = {d},
        \\  -- `vramDest_cannon` as a byte offset into SNES VRAM.
        \\  cannonAt = {d},
        \\
    , .{
        @as(u16, @truncate(inject.symbol("VarCurMissLo") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMaxMissLo") orelse return error.MissingSymbol)),
        screen.ram.health_lo,
        @as(u16, @truncate(inject.symbol("VarTanks") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMetReal") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMetDisp") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarActiveWeapon") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarBeam") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarCannonHold") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSfx1") orelse return error.MissingSymbol)),
        loadout.missiles,          loadout.max_missiles,
        loadout.health,            loadout.tanks,
        loadout.metroid_real,      loadout.metroid_displayed,
        @as(u16, @truncate(inject.symbol("VarAcidDmg") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSpikeDmg") orelse return error.MissingSymbol)),
        loadout.acid_damage,       loadout.spike_damage,
        try blocks_mod.compareIn(rom, 0, 0x2215),
        try blocks_mod.loadIn(rom, 0, 0x2225),
        try blocks_mod.loadAt(rom, 0x4F2C),
        @as(u32, try target.gbDestToObj(0x8080)) * 2,
    });
    for (inject.cannon_sheets, [_][]const u8{ "beamChr", "missileChr" }) |name, field| {
        try w.print("  {s} = {{", .{field});
        for (try cannon.bytesOf(set, name)) |b| try w.print("{d},", .{b});
        try w.print("}},\n", .{});
    }
    try w.print("}}\nlocal ms = {{}}\n", .{});

    // Step 13b, phase 20 and the band. Every number is the cartridge's; the
    // two symbols are where to look, not what to expect.
    try w.print(
        \\local HUD = {{
        \\  draw = 0x{X:0>6}, oam = {d}, itemCopy = {d}, dispH = {d}, health = {d}, sfx1 = {d},
        \\  -- 01:$4B2C, $4B47, $4B4B, $4B5A, $4B56 and $4B43.
        \\  y = {d}, yUp = {d}, x = {d}, spr = {d}, bit = {d}, majorEnd = {d},
        \\  -- 01:$4A89 and $4A85.
        \\  sfxTick = {d}, every = {d},
        \\  -- BG2's tilemap as a byte offset, and the band's first line in the window:
        \\  -- WY, 05:$40C0.
        \\  map = {d}, play = {d},
        \\}}
        \\
    , .{
        inject.symbol("DrawHudMetroid") orelse return error.MissingSymbol,
        @as(u16, @truncate(inject.symbol("VarOamBuf") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarItemCopy") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarDispHealthLo") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarHealthLo") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSfx1") orelse return error.MissingSymbol)),
        try blocks_mod.loadAt(rom, 0x4B2C),  try blocks_mod.loadAt(rom, 0x4B47),
        try blocks_mod.loadAt(rom, 0x4B4B),  try blocks_mod.addAt(rom, 0x4B5A),
        try blocks_mod.andIn(rom, 1, 0x4B56), try blocks_mod.compareAt(rom, 0x4B43),
        try blocks_mod.loadAt(rom, 0x4A89),  try blocks_mod.andIn(rom, 1, 0x4A85),
        @as(u32, @truncate(inject.symbol("ConstBg2Map") orelse return error.MissingSymbol)) * 2,
        try blocks_mod.loadIn(rom, 5, 0x40C0),
    });
    // The window's characters as the Game Boy shows them: `gfx_samusPowerSuit`'s
    // 2bpp tiles through BGP, one shade digit a pixel, and $FF -- the last tile
    // of `gfx_commonItems` -- the same way. Out of the ROM, not out of the
    // converted blob the engine uploads, so a conversion defect is a difference.
    {
        const sheet = offsets.find("gfx_samusPowerSuit").?;
        const items = offsets.find("gfx_commonItems").?;
        // Fields of `HUD` rather than locals of their own: this script is at
        // Lua's limit of 200 locals in one function.
        try w.print("HUD.tiles = {{\n", .{});
        for (0..256) |id| {
            const tile: []const u8 = if (id >= 0x9C and id <= 0xAF)
                rom[sheet.romOffset() + id * 16 ..][0..16]
            else if (id == 0xFF)
                rom[items.romOffset() + items.size - 16 ..][0..16]
            else
                continue;
            try w.print("  [{d}] = ", .{id});
            try writeShades(w, tile);
            try w.print(",\n", .{});
        }
        try w.print("}}\n", .{});
        try writeBar(rom, w);
        try w.print("local hud = {{}}\n", .{});
    }

    // Step 13c, phase 21: the Alpha's two effects the enemy oracle cannot see.
    // Everything is the engine's own symbol, for `B4c`'s reason.
    try w.print(
        \\local AL = {{
        \\  cutscene = {d}, hold = {d}, holdCutscene = {d}, weapon = {d}, beam = {d},
        \\  fight = {d}, state = {d}, stun = {d}, stunN = {d}, collDir = {d},
        \\  sprAlpha = {d}, stateFight = {d}, missile = {d},
        \\  -- 02:$6C44, the plain Alpha, as the slot's AI word.
        \\  ai = 0x6C44,
        \\}}
        \\local al = {{}}
        \\
    , .{
        @as(u16, @truncate(inject.symbol("VarCutscene") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarCannonHold") orelse return error.MissingSymbol)),
        try symByte("ConstCannonHoldCutscene"),
        @as(u16, @truncate(inject.symbol("VarActiveWeapon") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarBeam") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMetFight") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMetState") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarAlphaStun") orelse return error.MissingSymbol)),
        try symByte("ConstAlphaStunN"),
        @as(u16, @truncate(inject.symbol("VarCollWeaponDir") orelse return error.MissingSymbol)),
        try symByte("ConstSprAlpha1"),
        try symByte("ConstMetStateFight"),
        try symByte("ConstWpnMissile"),
    });

    // Step 13d, phase 22: the kill, on the cart.
    try w.print(
        \\-- Fields of phase 21's tables rather than two more locals: the main chunk
        \\-- is at Lua's limit of 200.
        \\AL.KL = {{
        \\  postDeath = {d}, quake = {d}, metSong = {d}, song = {d}, real = {d}, disp = {d},
        \\  shuffle = {d}, reload = {d}, frame = {d}, door = {d}, cutscene = {d},
        \\  dying = {d}, died = {d}, sprExp = {d}, songKilled = {d}, shuffleN = {d},
        \\  postDeathN = {d}, restore = {d}, expN = {d}, atCount = {d}, digit = {d},
        \\}}
        \\al.kl = {{}}
        \\
    , .{
        @as(u16, @truncate(inject.symbol("VarMetPostDeath") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarQuakeNext") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMetSong") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSong") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMetReal") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarMetDisp") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarShuffle") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSpawnReload") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarFrameCount") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarDoorIndex") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarCutscene") orelse return error.MissingSymbol)),
        try symByte("ConstMetStateDying"),
        try symByte("ConstMetFightDied"),
        try symByte("ConstSprExpBig"),
        try symByte("ConstSongMetroidKilled"),
        try symByte("ConstMetShuffle"),
        try symByte("ConstPostDeathN"),
        try symByte("ConstSongRestore"),
        try symByte("ConstMetExpN"),
        try symByte("ConstHudAtCount"),
        try symByte("ConstHudDigit"),
    });

    // Step 14, phase 23: the Metroid chain. The gate first: door $04A is the
    // `$F:$05` door into `$B:$0C` that a playtest found full of acid after a
    // kill, and its script is decoded here at both counts by the same walker
    // `transition.zig` grades against a running Game Boy -- so the table and the
    // frames the phase expects at each count are the Game Boy's.
    //
    // Door $0D9 (217, `$C:$B1`) is the second: two gates, `$42` ahead of `$46`,
    // so it runs `lavaCaves` 7, 8 and 6 as the count falls -- all three variants
    // B8 asks to see swapped, where door $04A shows two.
    // `bank` is `!MapIndex`'s form, the ROM's bank less `room.map_bank_first`:
    // this decodes the ROM's stream, where phase 8 reads the converted one.
    const gate_doors = [_]struct { door: u16, met: u8 }{
        .{ .door = 0x04A, .met = 0x47 }, .{ .door = 0x04A, .met = 0x46 },
        .{ .door = 0x0D9, .met = 0x47 }, .{ .door = 0x0D9, .met = 0x46 },
        .{ .door = 0x0D9, .met = 0x42 },
    };
    var gate: [gate_doors.len]struct { door: u16, met: u8, frames: usize, table: u4, bank: u8, pos: u8 } = undefined;
    for (&gate, gate_doors) |*g, d| {
        const met = d.met;
        const s = try transition.script(rom, d.door, met);
        g.* = .{ .door = d.door, .met = met, .frames = transition.scriptFrames(s, trans_dir_right), .table = 0, .bank = 0, .pos = 0 };
        var have_table = false;
        var have_warp = false;
        for (s.ops[0..s.count]) |op| switch (op) {
            .tiletable => |t| {
                g.table = t;
                have_table = true;
            },
            .warp => |v| {
                g.bank = @as(u8, v.bank) - room.map_bank_first;
                g.pos = v.pos;
                have_warp = true;
            },
            else => {},
        };
        if (!have_table or !have_warp) return error.GateDoorChanged;
    }
    // The phase is only a fixture if each count disagrees with the one before
    // it on the table -- and door $0D9 has to reach all three variants.
    if (gate[0].table == gate[1].table or gate[2].table == gate[3].table or
        gate[3].table == gate[4].table or gate[2].table == gate[4].table)
        return error.GateDoorChanged;
    try w.print(
        \\AL.MC = {{
        \\  tileTable = {d}, dir = {d},
        \\  gate = {{
        \\
    , .{
        @as(u16, @truncate(inject.symbol("VarTileTable") orelse return error.MissingSymbol)),
        trans_dir_right,
    });
    for (gate) |g| try w.print(
        "    {{ door = {d}, met = {d}, frames = {d}, table = {d}, bank = {d}, cell = {d} }},\n",
        .{ g.door, g.met, g.frames, g.table, g.bank, g.pos },
    );
    try w.print("  }},\n}}\nal.mc = {{}}\n\n", .{});
    // Step 22: the room each gate arrives in, expanded through the table the
    // *ROM's* pointer names (`screens.metatileTable`), for `checkEdge`. Code
    // 224 above asks only which operand the engine holds; this asks what it
    // drew with it, which is where the lava slots were wrong -- every lava
    // room one acid level high, because the cart's `TileTableBases` came from
    // `tiletable_order` in layout order.
    std.debug.assert(crossings[0].dir == trans_dir_right);
    try w.print("AL.MC.expand = {{}}\n", .{});
    for (gate, 1..) |g, i| {
        const room_cells = try expandedCells(gpa, rom, g.bank, @truncate(g.pos >> 4), @truncate(g.pos), g.table);
        defer gpa.free(room_cells);
        try w.print("AL.MC.expand[{d}] = {{}}\n", .{i});
        for (room_cells) |e| {
            try w.print("AL.MC.expand[{d}][{d}] = {{", .{ i, e.cell });
            for (e.tiles) |t| try w.print("{d},", .{t});
            try w.print("}}\n", .{});
        }
    }
    try w.print("\n", .{});
    // And the acid it is for, graded at the end of the phase.
    try w.print("AL.MC.acidContact, AL.MC.invuln, AL.MC.blockAcid = {d}, {d}, {d}\n\n", .{
        @as(u16, @truncate(inject.symbol("VarAcidContact") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarInvuln") orelse return error.MissingSymbol)),
        try symByte("ConstBlockAcid"),
    });

    // And the quake. The door that asks for a song while one is running is
    // $026, `WARP $B,$12; SONG $5`, decoded here so the song id is the ROM's.
    const song_door: u16 = 0x026;
    const song_id: u4 = blk: {
        const s = try transition.script(rom, song_door, 0x46);
        for (s.ops[0..s.count]) |op| switch (op) {
            .song => |v| break :blk v,
            else => {},
        };
        return error.GateDoorChanged;
    };
    try w.print(
        \\AL.MC.quakeNext, AL.MC.quakeTimer, AL.MC.afterQuake, AL.MC.roar = {d}, {d}, {d}, {d}
        \\AL.MC.shake, AL.MC.songInt, AL.MC.songPlaying = {d}, {d}, {d}
        \\AL.MC.len, AL.MC.lenLast, AL.MC.intQuake, AL.MC.intEnd = {d}, {d}, {d}, {d}
        \\AL.MC.shakeBit, AL.MC.samusBit, AL.MC.songDoor, AL.MC.songId = {d}, {d}, {d}, {d}
        \\
    , .{
        @as(u16, @truncate(inject.symbol("VarQuakeNext") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarQuakeTimer") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSongAfterQuake") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarQueenRoar") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarQuakeShake") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSongInt") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSongPlaying") orelse return error.MissingSymbol)),
        try symByte("ConstQuakeLen"),
        try symByte("ConstQuakeLenLast"),
        try symByte("ConstSongIntQuake"),
        try symByte("ConstSongIntEnd"),
        try symByte("ConstQuakeShakeBit"),
        try symByte("ConstQuakeSamusBit"),
        song_door,
        song_id,
    });
    try w.print(
        \\AL.RO = {{ on = {d}, dirty = {d}, bandTm = {d}, char = {d}, colon = {d}, map = {d}, at = {d} }}
        \\al.ro = {{}}
        \\AL.SP = {{ contact = {d}, fallArc = {d}, solid = {d}, colTab = {d}, left = {d}, bottom = {d}, item = {d}, roll = {d}, fall = {d}, jump = {d}, rest = {d}, bombed = {d} }}
        \\al.sp = {{}}
        \\
    , .{
        @as(u16, @truncate(inject.symbol("VarReadout") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarReadoutDirty") orelse return error.MissingSymbol)),
        @as(u16, @truncate((inject.symbol("VarBands") orelse return error.MissingSymbol) + 1)),
        try symByte("ConstReadoutChar"),
        try symByte("ConstReadoutColon"),
        @as(u16, @truncate(inject.symbol("ConstReadoutMap") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("ConstReadoutAt") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSpiderContact") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarFallArc") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarSolid") orelse return error.MissingSymbol)),
        @as(u16, @truncate(inject.symbol("VarColTab") orelse return error.MissingSymbol)),
        try symByte("ConstSpiderXLeft"),
        try symByte("ConstSpiderYBottom"),
        try symByte("ConstItemSpider"),
        try symByte("ConstPoseSpiderRoll"),
        try symByte("ConstPoseSpiderFall"),
        try symByte("ConstPoseSpiderJump"),
        try symByte("ConstPoseSpider"),
        try symByte("ConstPoseMorphBombed"),
    });
    // Step 15a's save station. `bottom` and `left` are `collision_samusBottom`'s
    // own probe, OAM bias and all, so the floor laid under her is the row and
    // column that routine reads.
    const sym16 = struct {
        fn f(name: []const u8) !u32 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.f;
    try w.print(
        \\AL.SV = {{ contact = {d}, cooldown = {d}, due = {d}, buf = {d}, prevBank = {d}, igtMin = {d}, igtHours = {d},
        \\  acid = {d}, spike = {d}, spawnSave = {d}, spawnFlags = {d}, solid = {d}, colTab = {d}, blockSave = {d},
        \\  bottom = {d}, left = {d}, cooldownN = {d}, items = {d}, beam = {d}, tanks = {d}, healthLo = {d},
        \\  maxMissLo = {d}, curMissLo = {d}, facing = {d}, song = {d}, metReal = {d}, metDisp = {d},
        \\  camX = {d}, camY = {d}, sfx1 = {d}, sfxSaved = {d} }}
        \\al.sv = {{}}
        \\
    , .{
        try sym16("VarSaveContact"),   try sym16("VarSaveCooldown"), try sym16("VarSaveDue"),
        try sym16("VarSaveBuf"),       try sym16("VarPrevBank"),     try sym16("VarIgtMinutes"),
        try sym16("VarIgtHours"),      try sym16("VarAcidDmg"),      try sym16("VarSpikeDmg"),
        (try sym16("VarSpawnSaveBuf")) & 0xFFFF, try sym16("VarSpawnFlags"), try sym16("VarSolid"),
        try sym16("VarColTab"),        try symByte("ConstBlockSave"),
        @as(u16, physics.oam_y_ofs) + @as(u16, @intCast(physics.origin_y_to_bottom)),
        @as(u16, physics.oam_x_ofs) + @as(u16, @intCast(physics.origin_x_to_left)) + 1,
        try symByte("ConstSaveCooldown"),
        try sym16("VarItems"),         try sym16("VarBeam"),         try sym16("VarTanks"),
        try sym16("VarHealthLo"),      try sym16("VarMaxMissLo"),    try sym16("VarCurMissLo"),
        try sym16("VarFacing"),        try sym16("VarSong"),         try sym16("VarMetReal"),
        try sym16("VarMetDisp"),       try sym16("VarCamX"),         try sym16("VarCamY"),
        try sym16("VarSfx1"),          try symByte("ConstSfxSaved"),
    });
    try w.print("AL.SV.pressStart, AL.SV.completed = {d}, {d}\n", .{
        try symByte("ConstSprSavePressStart"), try symByte("ConstSprSaveCompleted"),
    });

    // The two crossings, each with the frames a Game Boy spends on this script
    // going that way -- three strips cost two waits and four cost three, so the
    // duration is not the same number twice.
    try w.print("local CROSSINGS = {{\n", .{});
    for (crossings) |c| {
        try w.print(
            "  {{ dir = {d}, axis = {d}, frames = {d}, name = \"{s}\", starts = {{",
            .{ c.dir, c.axis, transition.scriptFrames(script, c.dir), c.name },
        );
        for (c.starts) |st| try w.print(" {{{d},{d}}},", .{ st[0], st[1] });
        try w.print(" }} }},\n", .{});
    }
    try w.print("}}\n\n", .{});

    // The cells the incoming edge can be drawn from, keyed by cell index and
    // expanded through the table the script selects. Baked from the ROM's map
    // data for the same reason the screens are baked -- a Lua reimplementation
    // would agree with the engine's mistakes as readily as with its
    // correctness. See `expandedCells` for why it is cells and not slots.
    try w.print("-- The rooms the incoming edge can be drawn from: {d} cells.\n", .{expanded.len});
    try w.print("local EXPAND = {{}}\n", .{});
    for (expanded) |e| {
        try w.print("EXPAND[{d}] = {{", .{e.cell});
        for (e.tiles, 0..) |t, i| {
            if (i % 32 == 0) try w.print("\n ", .{});
            try w.print("{d},", .{t});
        }
        try w.print("\n}}\n", .{});
    }
    try w.print("\n", .{});
    // OBP1, as the builder converts it: the palette `PutObject` selects for a
    // Game Boy object with bit 4 of its attribute set. Its own `print` for the
    // thirty-two-argument ceiling below. A global and not a `local`: the
    // script's main chunk is at Lua's 200 locals.
    try w.print("OBJ_PALETTE1 = {{ {d}, {d}, {d}, {d} }}\n", .{
        boot.obj_palette[4], boot.obj_palette[5], boot.obj_palette[6], boot.obj_palette[7],
    });

    try w.print(
        \\-- Drawing Samus.
        \\local OBJ_PALETTE = {{ {d}, {d}, {d}, {d} }}
        \\local RAM_FACING, RAM_SPRID = {d}, {d}
        \\local RAM_SPRX, RAM_SPRY, RAM_OAMIDX = {d}, {d}, {d}
        \\local OAM_X_OFS, OAM_Y_OFS = {d}, {d}
        \\local GUIDE_BIAS_Y, SPR_Y_OVER_GUIDE = {d}, {d}
        \\-- The most of the window she may cover: sixteen 8x8 parts, one more
        \\-- than the largest metasprite the reachable poses use. A mask that grew
        \\-- past this would mean the comparison had stopped comparing.
        \\local MASK_MAX = 16 * 64
        \\
    , .{
        boot.obj_palette[0],         boot.obj_palette[1],
        boot.obj_palette[2],         boot.obj_palette[3],
        screen.ram.facing,           screen.ram.sprite_id,
        screen.ram.sprite_x,         screen.ram.sprite_y,
        screen.ram.oam_index,
        physics.oam_x_ofs,           physics.oam_y_ofs,
        screen.guide.bias_y,         screen.guide.sprite_y_over_guide,
    });

    try w.print(
        \\-- The camera origin: the render's pixel (0, 0) is what the camera sees
        \\-- when it stands on the top-left clamp, so the window's corner in the
        \\-- render is the camera minus these.
        \\local CAM_ORIGIN_X, CAM_ORIGIN_Y = {d}, {d}
        \\-- The camera positions where the whole window still lies on one screen.
        \\local WIN_MIN_X, WIN_MAX_X = {d}, {d}
        \\local WIN_MIN_Y, WIN_MAX_Y = {d}, {d}
        \\
        \\-- On this screen "{s}" is a wall and "{s}" is not, which is read out of
        \\-- the cell's scroll byte rather than chosen.
        \\local WALL_CLAMP, WALL_SIGN = {d}, {d}
        \\
        \\-- Where the camera holds her while she walks. `CameraGuideX` is
        \\-- `samus - camera + GUIDE_BIAS_X`, her centre in OAM space, and the
        \\-- camera servos it towards the target for the direction she is going:
        \\-- 56 pixels behind her and 104 ahead, mirrored by facing. Turning round
        \\-- is 48 pixels of camera travel, which is what "the camera gives her
        \\-- space in front" looks like on a television. Nothing else in this
        \\-- script would notice if the guide were wrong - the step bound would
        \\-- pass with any target at all - and it was a person watching hardware
        \\-- who pointed the behaviour out, so it is asserted here now.
        \\local GUIDE_BIAS_X, OPEN_GUIDE = {d}, {d}
        \\
        \\-- Walking is `WalkSpeed`: one pixel a frame in water, and otherwise the
        \\-- frame counter's low bit plus one, which alternates 2, 1 for three
        \\-- pixels every two frames. (Varia would make it a flat 2; `!Items` is
        \\-- zero here, and if that ever stops being true this bound is the thing
        \\-- that will say so.) So no frame may move her more than two pixels and
        \\-- no two frames may move her more than three.
        \\local WALK_MAX, WALK_PAIR_MAX = 2, 3
        \\-- The camera adds at most one pixel of its own on top of a walk step,
        \\-- pulling Samus back towards the guide.
        \\local CAM_MAX_STEP = 3
        \\
        \\local STILL_FOR, WALL_HOLD, JUMP_RISE = 8, 80, 32
        \\local CAM_RISE = 16
        \\local GIVE_UP = 900
        \\
    , .{
        screen.min_x,                screen.min_y,
        screen.window_min_x,         screen.window_max_x,
        screen.window_min_y,         screen.window_max_y,
        @tagName(plan.wall),         @tagName(plan.open),
        plan.wall_clamp,             plan.wall_sign,
        screen.guide.bias_x,         screen.guide.forDir(plan.open),
    });

    // The two screens, one string per row, one digit per pixel. A row at a time
    // keeps the generated file readable and lets the exit code name where the
    // picture first went wrong.
    try writeScreen(w, "SCREEN", here);
    try writeScreen(w, "SCREEN_AFTER", after);
    try writeSprites(w, set);

    try w.print(
        \\-- Mesen hands back a 256x239 overscan frame as a ONE-BASED lua table, so
        \\-- the pixel at (x, y) is buf[y * 256 + x + 1], and the visible frame starts
        \\-- (239 - 224) / 2 = 7 rows down. Both of those cost a round trip when they
        \\-- were assumed to be 0-based and 8: the picture matched at an offset of one
        \\-- in each axis and looked like an engine bug.
        \\local OVERSCAN = (239 - 224) // 2
        \\
        \\local function shade(px)
        \\  local r = (px >> 16) & 0xFF
        \\  if r > 200 then return 0 elseif r > 120 then return 1
        \\  elseif r > 40 then return 2 else return 3 end
        \\end
        \\
        \\local function rd16(a, m) return emu.read(a, m) + 256 * emu.read(a + 1, m) end
        \\
        \\-- A packed `screen<<8 | pixel` difference, as a magnitude. Both
        \\-- coordinates wrap in twelve bits, so a step backwards across a screen
        \\-- boundary is a large positive number rather than a negative one.
        \\local function delta(now, was)
        \\  local d = (now - was) & 0xFFF
        \\  if d >= 0x800 then d = 0x1000 - d end
        \\  return d
        \\end
        \\
        \\-- Where the camera has put Samus in the window it is showing. A camera
        \\-- that has stopped following her still draws a perfectly correct picture
        \\-- of somewhere she is not, so every comparison also asks this.
        \\local function expectVisible(camx, camy, samx, samy)
        \\  local wx = ((samx - camx) & 0xFFF) + CAM_ORIGIN_X
        \\  local wy = ((samy - camy) & 0xFFF) + CAM_ORIGIN_Y
        \\  if wx >= 0x800 then wx = wx - 0x1000 end
        \\  if wy >= 0x800 then wy = wy - 0x1000 end
        \\  if wx < 0 or wx >= VIEW_W or wy < 0 or wy >= VIEW_H then emu.stop(79) end
        \\end
        \\
        \\-- Cut the window the camera is looking at out of a baked screen and
        \\-- compare it with the framebuffer. The camera's screen nibbles say which
        \\-- cell it is in, which the caller has already checked; only the pixel
        \\-- halves place the window.
        \\-- What OAM is showing lags what the shadow holds by exactly one frame,
        \\-- and the lag is structural rather than incidental: `MainLoop` opens
        \\-- with `wai`, so the drawing for frame N runs after frame N's NMI has
        \\-- already uploaded what frame N-1 composed. It is the same frame of lag
        \\-- the camera has, and the Game Boy has it too. Everything that reads OAM
        \\-- reads it against these rather than against this frame's variables.
        \\--
        \\-- Declared here, above the first function that reads them, because a lua
        \\-- local is not in scope in a closure written before it: an earlier
        \\-- version declared them below `spriteMask` and `spriteMask` silently
        \\-- captured a global nil instead. The arithmetic error that produced does
        \\-- not stop Mesen - it disables the callback - so the symptom was the
        \\-- whole run timing out, which reads exactly like a cart that hung.
        \\local oamShown, shownX, shownY, shownId, shownText = 0, nil, nil, nil, 0
        \\
        \\-- Where Samus is, in the window's own coordinates, read out of the OAM
        \\-- the PPU is actually using rather than out of the shadow that fed it -
        \\-- so a DMA that never ran shows up here as an empty mask.
        \\--
        \\-- Only the slots this frame's drawing filled are read. A slot past that
        \\-- is parked off-screen and holds last frame's character, and treating it
        \\-- as live would mask a rectangle nothing is drawn in.
        \\local function spriteMask()
        \\  local oam = emu.memType.snesSpriteRam
        \\  local used = oamShown
        \\  local mask, n = {{}}, 0
        \\  for i = 0, (used // 4) - 1 do
        \\    local x = emu.read(i * 4, oam)
        \\    local y = emu.read(i * 4 + 1, oam)
        \\    local hi = emu.read(512 + (i >> 2), oam)
        \\    local ninth = (hi >> ((i & 3) * 2)) & 1
        \\    if ninth == 0 then
        \\      -- Screen coordinates into window ones. A part that falls outside
        \\      -- the window is one the window is already masking on the PPU's
        \\      -- behalf; it contributes nothing here either.
        \\      for dy = 0, 7 do
        \\        local wy = y + dy - BAND_TOP
        \\        if wy >= 0 and wy < VIEW_H then
        \\          for dx = 0, 7 do
        \\            local wx = x + dx - WIN_LEFT
        \\            if wx >= 0 and wx < VIEW_W then
        \\              local k = wy * VIEW_W + wx
        \\              if not mask[k] then mask[k] = true; n = n + 1 end
        \\            end
        \\          end
        \\        end
        \\      end
        \\    end
        \\  end
        \\  return mask, n
        \\end
        \\
        \\-- Cut the window the camera is looking at out of a baked screen and
        \\-- compare it with the framebuffer. The camera's screen nibbles say which
        \\-- cell it is in, which the caller has already checked; only the pixel
        \\-- halves place the window.
        \\--
        \\-- The baked render has no Samus in it, so the pixels she covers are
        \\-- skipped. The mask is computed from where OAM actually puts her rather
        \\-- than from a box around where she ought to be: a hardcoded box would go
        \\-- on masking the same rectangle after the sprite stopped being drawn
        \\-- there, which is the one failure this check exists to catch.
        \\local function compareAt(scr, camx, camy, base, cap)
        \\  local left = (camx & 0xFF) - CAM_ORIGIN_X
        \\  local top  = (camy & 0xFF) - CAM_ORIGIN_Y
        \\  if left < 0 or top < 0 or left + VIEW_W > SCREEN_PX or top + VIEW_H > SCREEN_PX then
        \\    emu.stop(17)
        \\  end
        \\  local mask, masked = spriteMask()
        \\  if masked == 0 or masked > MASK_MAX then emu.stop(127) end
        \\  local buf = emu.getScreenBuffer()
        \\  for y = 0, VIEW_H - 1 do
        \\    local row = scr[top + y + 1]
        \\    for x = 0, VIEW_W - 1 do
        \\      if not mask[y * VIEW_W + x] then
        \\        local px = buf[(BAND_TOP + OVERSCAN + y) * 256 + WIN_LEFT + x + 1]
        \\        -- **From WY down it is the window, since Step 13b**: the status
        \\        -- bar covers the play field there on the Game Boy, so the picture
        \\        -- to match is BG2's tile at that column and not the baked screen.
        \\        -- Which tile is the HUD oracle's to grade; this grades that the
        \\        -- band shows it -- the characters, the scroll and the HDMA split.
        \\        local want
        \\        if y >= HUD.play then
        \\          local t = HUD.tiles[emu.read(HUD.map + (x // 8) * 2, vram)]
        \\          if t == nil then emu.stop(204) end
        \\          local k = (y - HUD.play) * 8 + x % 8 + 1
        \\          want = tonumber(t:sub(k, k))
        \\          if shade(px) ~= want then emu.stop(204) end
        \\        else
        \\          want = tonumber(row:sub(left + x + 1, left + x + 1))
        \\        end
        \\        if shade(px) ~= want then
        \\          local code = base + (y >> 3)
        \\          if code > cap then code = cap end
        \\          emu.stop(code)
        \\        end
        \\      end
        \\    end
        \\  end
        \\end
        \\
        \\-- Boot. None of this depends on where the camera is standing, so it runs
        \\-- once, before Samus has finished the fall she starts in.
        \\local function checkBoot()
        \\  if rd16(0, cgram) == 0x7C1F then emu.stop(10) end
        \\  if rd16(RAM_FRAMES, wram) < 5 then emu.stop(11) end
        \\
        \\  local chr = 0
        \\  for i = 0, 4095 do if emu.read(i, vram) ~= 0 then chr = chr + 1 end end
        \\  if chr == 0 then emu.stop(12) end
        \\
        \\  local words = 0
        \\  for i = 0, 1023 do if rd16(0x1000 + i * 2, vram) ~= 0 then words = words + 1 end end
        \\  if words == 0 then emu.stop(13) end
        \\  -- Step 24g: the window's second row is `saveTextTilemap`, which
        \\  -- `loadTitleScreen` copies there (05:$40A0) and the bar shows at a
        \\  -- station. Palette 0, no priority, as `HudPut` writes the first row.
        \\  for i = 0, #HUD.boot - 1 do
        \\    if rd16(HUD.map + 64 + i * 2, vram) ~= HUD.boot[i + 1] then emu.stop(3) end
        \\  end
        \\
        \\  if emu.read(RAM_CELL, wram) ~= CELL then emu.stop(14) end
        \\  -- Boot record version 11: what she carries. Every cart before it
        \\  -- booted with none of this, and a playtest's missile was a dud.
        \\  if rd16(MS.cur, wram) ~= MS.wantCur then emu.stop(197) end
        \\  if rd16(MS.max, wram) ~= MS.wantMax then emu.stop(197) end
        \\  if rd16(MS.health, wram) ~= MS.wantHealth then emu.stop(197) end
        \\  if emu.read(MS.tanks, wram) ~= MS.wantTanks then emu.stop(197) end
        \\  if emu.read(MS.metReal, wram) ~= MS.wantReal then emu.stop(197) end
        \\  if emu.read(MS.metDisp, wram) ~= MS.wantDisp then emu.stop(197) end
        \\  -- Version 15: and the damage a room does, or acid takes nothing off.
        \\  if emu.read(MS.acid, wram) ~= MS.wantAcid then emu.stop(197) end
        \\  if emu.read(MS.spike, wram) ~= MS.wantSpike then emu.stop(197) end
        \\  for i = 0, 3 do
        \\    if rd16(i * 2, cgram) ~= PALETTE[i + 1] then emu.stop(15) end
        \\    -- The object half of CGRAM. Colour $80 is the first object
        \\    -- palette, which is where OBP0 goes; entry 0 of it is never shown
        \\    -- and is checked anyway, because it is written.
        \\    if rd16(0x100 + i * 2, cgram) ~= OBJ_PALETTE[i + 1] then emu.stop(15) end
        \\    -- And OBP1 in object palette 1, which `PutObject` selects for bit 4
        \\    -- of a Game Boy attribute. An object palette is sixteen colours, so
        \\    -- palette 1 is colour $90, not the $84 after OBP0's four: the
        \\    -- frozen enemy, a stunned one's flash and a blinking drop drew
        \\    -- black until 1.0 Step 8b's playtest (`docs/bug_tracker.md`).
        \\    if rd16(0x120 + i * 2, cgram) ~= OBJ_PALETTE1[i + 1] then emu.stop(15) end
        \\  end
        \\end
        \\
        \\-- The input pair. `ReadPad` keeps the held state and derives the rising
        \\-- edge from it the way the original does - (prev XOR current) AND current -
        \\-- so a direction the gate holds down has to read as held on every frame of
        \\-- the hold and as *newly* pressed on exactly one of them.
        \\--
        \\-- A press takes a frame or two to reach the engine: the gate sets the pad
        \\-- from `inputPolled` and the engine reads it in the NMI, so the first
        \\-- frames of a hold are still on their way. `seen` waits for the press to
        \\-- arrive - and the edge is looked at from that same frame on, because the
        \\-- edge fires on exactly the frame the held state first turns on.
        \\local rose = {{ [WALL_BIT] = 0, [OPEN_BIT] = 0 }}
        \\local seen = {{ [WALL_BIT] = false, [OPEN_BIT] = false }}
        \\local function expectHeld(bit, waited)
        \\  local h = rd16(RAM_HELD, wram) & bit
        \\  if not seen[bit] then
        \\    if h == 0 then
        \\      if waited > 5 then emu.stop(76) end
        \\      return
        \\    end
        \\    seen[bit] = true
        \\  elseif h == 0 then
        \\    emu.stop(76)
        \\  end
        \\  if (rd16(RAM_EDGE, wram) & bit) ~= 0 then rose[bit] = rose[bit] + 1 end
        \\  if rose[bit] > 1 then emu.stop(77) end
        \\end
        \\
        \\local frames, phase, since, hold = 0, 0, 0, nil
        \\local still, prevY, prevX, prevCam, prevCamY = 0, nil, nil, nil, nil
        \\local wallStill, hitWall, prevWallX = 0, false, nil
        \\local guideLocked = false
        \\local startScreenY, groundY, groundCamY = nil, nil, nil
        \\local apex, camApex, linearTop = 0, nil, nil
        \\local sawStart, sawJump, lastWalk = false, false, 0
        \\
        \\local function enter(p, button)
        \\  phase, since, hold = p, 0, button
        \\  still, prevY, prevX, prevCam, prevCamY, lastWalk = 0, nil, nil, nil, nil, 0
        \\end
        \\
        \\-- Every frame she is walking: no frame may carry her further than a walk
        \\-- step, and no two frames further than a walk and a half. Step 12a's
        \\-- equivalent check was on the camera and was an equality, because the
        \\-- camera moved by a constant; Samus moves by the ROM's own speed rule,
        \\-- so this is the bound that rule implies rather than a single number.
        \\local function checkWalk(x)
        \\  if prevX ~= nil then
        \\    local d = delta(x, prevX)
        \\    if d > WALK_MAX then emu.stop(66) end
        \\    if d + lastWalk > WALK_PAIR_MAX then emu.stop(67) end
        \\    lastWalk = d
        \\  end
        \\  prevX = x
        \\end
        \\
        \\-- The guide, while she walks. It takes the camera some frames to catch up
        \\-- after a direction change - 48 pixels of travel, a pixel a frame on top
        \\-- of the walk - so this waits for it to arrive and then holds it there.
        \\-- One pixel of slack is the servo's own dead band.
        \\local function checkGuide(camx, samx)
        \\  local g = (samx - camx + GUIDE_BIAS_X) & 0xFF
        \\  if g == OPEN_GUIDE then
        \\    guideLocked = true
        \\  elseif guideLocked then
        \\    local off = g - OPEN_GUIDE
        \\    if off < 0 then off = -off end
        \\    if off > 1 then emu.stop(18) end
        \\  end
        \\end
        \\
        \\-- The camera, while she walks: at most her step plus the one pixel the
        \\-- guide pulls. Step 12 clamped and teleported instead of scrolling, and
        \\-- on hardware that read as the picture skipping a whole viewport in one
        \\-- press - which is what this is here to catch.
        \\local function checkCamStep(cam)
        \\  if prevCam ~= nil and delta(cam, prevCam) > CAM_MAX_STEP then emu.stop(74) end
        \\  prevCam = cam
        \\end
        \\
        \\-- Samus's sprite, every frame. Three separate claims, because three
        \\-- different things can be wrong and only one of them shows up as a
        \\-- picture that looks odd:
        \\--
        \\--   the anchor is the camera guide with the biases exchanged. That is
        \\--   the whole answer to `01-requirements.md`'s question about
        \\--   OAM_X_OFS and OAM_Y_OFS - they stay in the guide arithmetic, where
        \\--   they are load-bearing, and come off again at the OAM write, where
        \\--   the SNES has no equivalent. Vertically the sprite sits two pixels
        \\--   below the guide, which is the original's own divergence.
        \\--
        \\--   the walk produced the number of parts the cart's own data says the
        \\--   id has, so a terminator read early or late fails here rather than
        \\--   as a smear of tiles.
        \\--
        \\--   the first part's OAM entry is the anchor plus that part's offset,
        \\--   with the Game Boy biases off and the window offsets on. This is the
        \\--   arithmetic `DrawSprite` does, checked against numbers the builder
        \\--   computed independently.
        \\-- The OAM half of this is made against the previous frame's anchor, for
        \\-- the lag reason given above - held rather than papered over by only
        \\-- ever checking her at rest, because a check that ran only at rest would
        \\-- not notice a sprite that lagged by two frames instead of one.
        \\local sawStandId, sawJumpId = nil, nil
        \\local walkIds = {{}}
        \\-- Where the camera and Samus stood when the door index was written, so
        \\-- phase 8 can assert which half of each position the warp left alone.
        \\local warpFrom = nil
        \\-- Phase 9's. `pickAt` is the frame the lever was pulled, `gotAt` how
        \\-- long after that the item bit landed, and `pickX`/`pickY` where
        \\-- Samus was standing when it was -- she must not move again until the
        \\-- jingle is spent.
        \\local pickAt, gotAt, pickX, pickY, itemsBefore = nil, nil, nil, nil, nil
        \\-- Phase 10's: which half of the gating test is running, the bits the
        \\-- pickup left, and when the current half started.
        \\local bombTry, bombBits, bombAt = nil, nil, nil
        \\local dbgMoved, dbgFall, dbgMorph, dbgGround, dbgY, dbgPrev = 0, 0, 0, 0, nil, nil
        \\-- Phases 11 and 12's. `blkAt` is the frame the slot was written,
        \\-- `blkSlot` the tilemap index this script derived for it on its own,
        \\-- and `blkHoldY`/`blkHoldX` the pixel Samus is pinned to while the
        \\-- floor under her comes and goes.
        \\local blkAt, blkSlot, blkHoldY, blkHoldX = nil, nil, nil, nil
        \\local blkSawGone, blkSawFall, blkSawBack, blkSeen = false, false, false, {{}}
        \\local evictAt = nil
        \\-- Phases 13 and 14's, in a table for the reason `B5` is one. `at` is
        \\-- the frame the fire button was pressed, `slot` the projectile slot
        \\-- the cart chose, `blk` the tilemap index this script put a block at,
        \\-- and `hp` the health the enemy had before it was shot.
        \\local shot = {{ at = nil, slot = nil, blk = nil, dir = nil, enAt = nil, hp = nil,
        \\                drawAt = nil, enY = nil, enX = nil, samusParts = nil,
        \\-- And Step 12e's, in the same table. `kAt` is the frame the killing shot
        \\-- was fired, `kAim` the projectile-space x the corpse stood at, `kSeen`
        \\-- which frames of the explosion were on the screen, and `dTries` how many
        \\-- corpses the drop phase has had to make: the roll is a coin flip and a
        \\-- rung that depended on one outcome would fail half the time.
        \\                kAt = nil, kSlot = nil, kAim = nil, kKill = nil,
        \\                kSeen = nil, kFree = nil, kFire = nil, kAgain = nil,
        \\                dAt = nil, dTries = 0, dGot = nil, dLo = false,
        \\                dHi = false, dTake = nil, hadProj = false,
        \\                pLo = false, pHi = false }}
        \\
        \\-- The projectile array as the cart holds it: the first live slot's
        \\-- offset, or nil. Read and never written -- the lever for these two
        \\-- phases is the fire button, not the array.
        \\-- How many of the objects in `[from, to)` have OAM's ninth x bit set.
        \\-- Two bits a sprite, four sprites a byte, starting at 512.
        \\local function ninthBits(from, to)
        \\  local oam = emu.memType.snesSpriteRam
        \\  local n, set = from // 4, 0
        \\  while n < to // 4 do
        \\    local hi = emu.read(512 + (n // 4), oam)
        \\    if (hi >> ((n % 4) * 2)) & 1 ~= 0 then set = set + 1 end
        \\    n = n + 1
        \\  end
        \\  return set
        \\end
        \\
        \\-- Phase 18's, in a table for the reason `shot` is one, with its two
        \\-- helpers on it: the first live bomb slot and how many there are, and
        \\-- the tilemap index of the 2x2 a Game Boy pixel is in, snapped the way
        \\-- `getTilemapAddress`'s `AND $DE` snaps it.
        \\local bm = {{}}
        \\function bm.live()
        \\  local first, n = nil, 0
        \\  for i = 0, BM.count - 1 do
        \\    local o = BM.bombs + i * BM.size
        \\    if emu.read(o, wram) ~= BM.none then
        \\      n = n + 1
        \\      if first == nil then first = o end
        \\    end
        \\  end
        \\  return first, n
        \\end
        \\function bm.slotAt(y, x)
        \\  local row = ((y - OAM_Y_OFS) & 0xF8) >> 3
        \\  local col = ((x - OAM_X_OFS) & 0xF8) >> 3
        \\  return (row * 32 + col) & 0xFFDE
        \\end
        \\
        \\local function liveProj()
        \\  for i = 0, B5.count - 1 do
        \\    local o = B5.projs + i * B5.size
        \\    if emu.read(o + B5.tType, wram) ~= B5.none then return o end
        \\  end
        \\  return nil
        \\end
        \\
        \\-- The four tilemap slots a block's 2x2 occupies, as the *engine* would
        \\-- have to write them: the pair, then the pair a row down. Derived here
        \\-- from the block's position rather than read back from the engine, so
        \\-- a `BlockSlotAddr` that snapped to the wrong grid would show.
        \\local function blkTiles(slot)
        \\  local a = emu.read(RAM_TILEMAP + slot * 2, wram)
        \\  local b = emu.read(RAM_TILEMAP + (slot + 1) * 2, wram)
        \\  local c = emu.read(RAM_TILEMAP + (slot + 32) * 2, wram)
        \\  local d = emu.read(RAM_TILEMAP + (slot + 33) * 2, wram)
        \\  return a, b, c, d
        \\end
        \\
        \\-- Whether those four are the run of four a drawing arm writes.
        \\local function blkIsRun(slot, base)
        \\  local a, b, c, d = blkTiles(slot)
        \\  return a == base and b == (base + 1) and c == (base + 2) and d == (base + 3)
        \\end
        \\
        \\local function blkIsGone(slot)
        \\  local a, b, c, d = blkTiles(slot)
        \\  return a == BLK_TILE_GONE and b == BLK_TILE_GONE
        \\    and c == BLK_TILE_GONE and d == BLK_TILE_GONE
        \\end
        \\hud.seen = {{}}
        \\-- **No memory callback here, and that is measured.** Reading the counter
        \\-- as `drawHudMetroid` entered was the obvious lever, and with one exec
        \\-- callback registered this script's framebuffer comparisons went from
        \\-- passing on every run to failing on some -- phase 7's neighbour at
        \\-- code 81 on some runs of the same cart and not others, with the state
        \\-- a per-frame dump recorded identical up to the frame. **Step 24d found
        \\-- why, and it was never the callback's fault**: Mesen skipped drawing
        \\-- frames by wall-clock time, so the framebuffer was stale by however
        \\-- many, and the callback's cost moved how many. `verify.zig`'s
        \\-- `draw_every_frame` turns that off; the callback was not retried
        \\-- after it. The counter the icon was drawn with is the one this frame's
        \\-- logic saw, which is the counter at the end of the frame less the NMIs
        \\-- since: `HUD.fcLag`, pinned by the icon's own check below.
        \\HUD.fcLag = 0
        \\function hud.logicFc() return (emu.read(RAM_FRAMES, wram) - HUD.fcLag) & 0xFF end
        \\
        \\-- The icon's first part in the OAM shadow, found by what it must be: one
        \\-- of its two sprites' first tile, at `drawHudMetroid`'s X and at one of
        \\-- its two Ys. Returns the sprite id and the Game Boy Y, or nil.
        \\function hud.icon(used)
        \\  for i = 0, used - 4, 4 do
        \\    local t = emu.read(HUD.oam + i + 2, wram)
        \\    for id = HUD.spr, HUD.spr + 1 do
        \\      local wx = (((HUD.x + SPR_DX[id]) & 0xFF) - OAM_X_OFS + WIN_LEFT) & 0xFF
        \\      if t == SPR_T0[id] and emu.read(HUD.oam + i, wram) == wx then
        \\        local y = emu.read(HUD.oam + i + 1, wram)
        \\        for _, gy in ipairs({{ HUD.y, HUD.yUp }}) do
        \\          if y == ((((gy + SPR_DY[id]) & 0xFF) - OAM_Y_OFS + BAND_TOP) & 0xFF) then return id, gy end
        \\        end
        \\      end
        \\    end
        \\  end
        \\  return nil
        \\end
        \\
        \\-- **The window on the screen while it is raised, Step 24g.** From WY $80
        \\-- down the band is BG2: its first row the status bar, one row higher than
        \\-- at $88, and its second the bar, which the Game Boy draws from `ITEM`'s
        \\-- name over `saveTextTilemap`. `rows` is how many of the two a phase can
        \\-- vouch for: the bar's glyphs are the item font only once an `ITEM` has
        \\-- loaded it, as on the Game Boy. Pixels under a sprite in hardware OAM
        \\-- are skipped: the icon sits on the status bar and the save text on the
        \\-- bar. 2 for the status bar's row, 4 for the bar's.
        \\function hud.bar(rows)
        \\  hud.barRan = (hud.barRan or 0) + 1
        \\  local oam = emu.memType.snesSpriteRam
        \\  local cover = {{}}
        \\  for e = 0, 127 do
        \\    local x, y = emu.read(e * 4, oam), emu.read(e * 4 + 1, oam)
        \\    if ((emu.read(512 + (e >> 2), oam) >> ((e & 3) * 2)) & 1) == 0 then
        \\      for dy = 0, 7 do
        \\        local by = y + dy - BAND_TOP - HUD.wyUp
        \\        if by >= 0 and by < 16 then
        \\          for dx = 0, 7 do
        \\            local bx = x + dx - WIN_LEFT
        \\            if bx >= 0 and bx < VIEW_W then cover[by * VIEW_W + bx] = true end
        \\          end
        \\        end
        \\      end
        \\    end
        \\  end
        \\  local buf = emu.getScreenBuffer()
        \\  for y = 0, rows * 8 - 1 do
        \\    local r = y // 8
        \\    local code = r == 0 and 2 or 4
        \\    for x = 0, VIEW_W - 1 do
        \\      if not cover[y * VIEW_W + x] then
        \\        local id = emu.read(HUD.map + r * 64 + (x // 8) * 2, vram)
        \\        local t = HUD.tiles[id]
        \\        if r == 1 then t = HUD.font[id] or t end
        \\        if t == nil then emu.stop(code) end
        \\        local k = (y % 8) * 8 + x % 8 + 1
        \\        local px = buf[(BAND_TOP + OVERSCAN + HUD.wyUp + y) * 256 + WIN_LEFT + x + 1]
        \\        if shade(px) ~= tonumber(t:sub(k, k)) then emu.stop(code) end
        \\      end
        \\    end
        \\  end
        \\end
        \\
        \\local function checkSprite(camx, camy, samx, samy)
        \\  local id = emu.read(RAM_SPRID, wram)
        \\  local used = rd16(RAM_OAMIDX, wram)
        \\  -- Step 24g's: whether this pass was a collection's (its stage was
        \\  -- set when the pass began, so `miscIngameTasks` did not run), the
        \\  -- window's Y the pass before left, and whether what that pass left
        \\  -- raises it -- `miscIngameTasks` is the pass's first call, so it reads
        \\  -- the contact and the copy before this pass's collision sets them.
        \\  local pickupPass, wyBefore, raiseBefore = (hud.stage or 0) ~= 0, hud.wyLast, hud.raiseLast
        \\  local copyNow = emu.read(HUD.itemCopy, wram)
        \\  hud.stage, hud.wyLast = emu.read(RAM_ITEMSTAGE, wram), emu.read(HUD.winY, wram)
        \\  hud.raiseLast = emu.read(AL.SV.contact, wram) ~= 0 or (copyNow ~= 0 and copyNow < HUD.majorEnd)
        \\  -- The save text, which `SaveStation` draws ahead of everything since
        \\  -- Step 15a: "COMPLETED" while the cooldown runs, and "PRESS START" on
        \\  -- bit 3 once it has run out, both only if the contact the *last* frame
        \\  -- left was set. The frame the save takes draws nothing, and neither
        \\  -- does one the door script owns, so their OAM is the frame before's and
        \\  -- so is their text.
        \\  local textParts = 0
        \\  if hud.dueBefore or rd16(RAM_DOORIDX, wram) ~= 0 or hud.doorBefore then
        \\    textParts = hud.textBefore or 0
        \\  elseif (hud.contactBefore or 0) ~= 0 then
        \\    if emu.read(AL.SV.cooldown, wram) ~= 0 then textParts = SPR_PARTS[AL.SV.completed]
        \\    elseif (hud.logicFc() & 0x08) ~= 0 then textParts = SPR_PARTS[AL.SV.pressStart] end
        \\  end
        \\  hud.textBefore = textParts
        \\  hud.contactBefore = emu.read(AL.SV.contact, wram)
        \\  hud.dueBefore = emu.read(AL.SV.due, wram) ~= 0
        \\  -- Whether the door script owned this frame, read before any early
        \\  -- return so the frame before's answer is always last frame's. The
        \\  -- index being set says so, and so does it having been set a frame ago:
        \\  -- `END` clears it on a frame that is still the interpreter's.
        \\  local door = rd16(RAM_DOORIDX, wram) ~= 0
        \\  local owned = door or hud.doorBefore
        \\  hud.doorBefore, hud.owned = door, owned
        \\  -- The frame a collection starts draws nothing, as the original's
        \\  -- `handleItemPickup` blocks before `drawSamus`. Since Step 12c the
        \\  -- index is zeroed at the top of the frame, where `waitOneFrame` zeroes
        \\  -- it, so that frame reads 0; before, `DrawSamus` zeroed it and never ran.
        \\  if used == 0 and emu.read(RAM_ITEMSTAGE, wram) ~= 0 then return id end
        \\  -- And the frame a missile toggle ends inside `beginGraphicsTransfer`'s
        \\  -- wait, which reaches neither `drawSamus` nor the enemy pass: Step 13a.
        \\  if used == 0 and emu.read(MS.hold, wram) ~= 0 then return id end
        \\  -- The HUD icon, on every frame that draws: Step 13b. It is composed
        \\  -- after Samus and the projectiles and before the enemies, so it is
        \\  -- counted into what she is compared against below.
        \\  local icon, iconY = hud.icon(used)
        \\  if icon == nil then emu.stop(205) end
        \\  -- Not on a frame the door script owns: `RunPendingTransition` ends the
        \\  -- pass before anything draws, as the original's interpreter does, so
        \\  -- OAM still holds the frame before's icon while the counter moves on.
        \\  -- That includes the `END` frame, which reads an index of zero; missing
        \\  -- it failed one crossing in sixteen, when bit 4 flipped on that frame.
        \\  if not owned and icon ~= HUD.spr + ((hud.logicFc() & HUD.bit) ~= 0 and 1 or 0) then emu.stop(206) end
        \\  hud.seen[icon] = true
        \\  local copy = emu.read(HUD.itemCopy, wram)
        \\  -- A major item's jingle raises it, and since Step 15a so does standing
        \\  -- on a save station (01:$4B37), which is the arm Step 13b ported and
        \\  -- nothing could reach. On a frame the door script owns the icon is the
        \\  -- frame before's, so it answers to the frame before's reason.
        \\  local up = (copy ~= 0 and copy < HUD.majorEnd) or emu.read(AL.SV.contact, wram) ~= 0
        \\  if owned then up = hud.upBefore else hud.upBefore = up end
        \\  if (iconY == HUD.yUp) ~= up then emu.stop(207) end
        \\  if up then hud.raised = true end
        \\  -- **And the window with it, Step 24g.** The same two reasons are the
        \\  -- ones `miscIngameTasks` raises `rWY` for (01:$5826, $582C); $88
        \\  -- otherwise (01:$580F). `!WinY` is the port's `rWY`. It reads them as
        \\  -- the pass before left them, so the window rises a pass after the
        \\  -- icon at a station, as on the Game Boy. A collection's
        \\  -- passes do not run `miscIngameTasks`: the jingle's loop raises it
        \\  -- itself (00:$3A21), and the loop after it, which waits for the orb
        \\  -- to go (00:$3A63), draws the icon with the copy cleared and leaves
        \\  -- `rWY` where the jingle put it -- so there the icon is down and the
        \\  -- window up until the main loop resumes, on the Game Boy as here. A
        \\  -- frame the door script owns runs none of it, and a door's `LOAD` or
        \\  -- `COPY` lowers it (00:$23FA, $240F), so it is not asked there. What
        \\  -- the screen shows for it is `hud.bar`'s.
        \\  if not owned then
        \\    local want = raiseBefore and HUD.wyUp or HUD.wy
        \\    if pickupPass then want = up and HUD.wyUp or wyBefore end
        \\    if emu.read(HUD.winY, wram) ~= want then emu.stop(1) end
        \\    -- The picture is a frame behind the logic: NMI applies what this
        \\    -- pass decided. So the screen is graded when two passes in a row
        \\    -- raised it, and only where a phase has lit the screen and says
        \\    -- which rows it can vouch for -- phase 28 alone: phases 9 to 27 run
        \\    -- at brightness 0, measured on phases 9 and 26.
        \\    if hud.barRows and up and hud.upLast then hud.bar(hud.barRows) end
        \\    hud.upLast = up
        \\  else
        \\    hud.upLast = nil
        \\  end
        \\  local iconParts = SPR_PARTS[icon]
        \\  hud.parts = iconParts
        \\  -- Step 22: `drawSamus`' acid flicker (01:$4BE8) skips her on four
        \\  -- frames in eight while the contact is set, and only then. On a frame
        \\  -- the door script owns nothing draws, so OAM and the answer are the
        \\  -- frame before's -- a crossing into a lava room lands her in acid.
        \\  local hidden = emu.read(AL.MC.acidContact, wram) ~= 0 and (hud.logicFc() & 0x04) == 0
        \\  if owned then hidden = hud.hiddenBefore or false else hud.hiddenBefore = hidden end
        \\  if hidden ~= (used == iconParts * 4) then emu.stop(hidden and 253 or 121) end
        \\  if hidden then
        \\    shownId = nil                -- nothing of hers reaches OAM to check next frame
        \\    return id
        \\  end
        \\
        \\  -- **Where Samus is, out of the byte the camera's door triggers
        \\  -- actually read.** Until Step 12b that was `hSpriteXPixel`, because
        \\  -- `drawSamus_common` writes it and `samus_onscreenXPos` from one
        \\  -- value and Samus was the only thing this engine drew. She is not
        \\  -- any more: `drawProjectiles` writes the sprite bytes and not the
        \\  -- on-screen pair, so a frame with a beam in the air leaves the
        \\  -- sprite bytes holding the *beam*. Asserting the trigger's own
        \\  -- variable is what makes this a test of which one it reads.
        \\  local onx = emu.read(B5.triggerX, wram)
        \\  local ony = emu.read(B5.onscreenY, wram)
        \\  if onx ~= ((samx - camx + GUIDE_BIAS_X) & 0xFF) then emu.stop(122) end
        \\  if ony ~= ((samy - camy + GUIDE_BIAS_Y + SPR_Y_OVER_GUIDE) & 0xFF) then emu.stop(122) end
        \\
        \\  -- And the aliasing itself, on the frames where it still holds: with
        \\  -- nothing else drawn the two pairs are one number, which is what
        \\  -- `drawSamus_common` writing both from one `A` means.
        \\  local sprx, spry = emu.read(RAM_SPRX, wram), emu.read(RAM_SPRY, wram)
        \\  -- **Samus is no longer the only thing this engine draws**, and
        \\  -- everything below here assumed she was. `!SpriteId`, `!SprX`,
        \\  -- `!SprY` and `!OamIdx` all hold whatever was drawn *last* -- a
        \\  -- projectile since Step 12b, an enemy since 12d -- so the id is not
        \\  -- hers to look up and the count is not hers to compare. The frames
        \\  -- where she is alone are still every frame of phases 1 through 12,
        \\  -- which is where this check earns its place; the two phases that
        \\  -- fire a shot have their own assertions and do not need this one.
        \\  --
        \\  -- **And the frame *after* a projectile counts too**, which took Step
        \\  -- 12e to find. `drawProjectiles` is where a beam that has left the
        \\  -- window is despawned -- the despawn is in the draw, 01:$5300 -- so on
        \\  -- that frame the beam was composed into OAM and `!SprX` holds it while
        \\  -- the array is already empty. No phase before 12e could reach it:
        \\  -- every earlier beam dies on an enemy or a block, inside
        \\  -- `handleProjectiles` and before anything draws it.
        \\  local live = liveProj() ~= nil
        \\  -- And a bomb: `drawBombs` puts its parts *ahead* of hers.
        \\  if live or shot.hadProj or emu.read(B5.enActive, wram) ~= 0 or bm.live() ~= nil then
        \\    shot.hadProj = live
        \\    shownId = nil
        \\    return id
        \\  end
        \\  shot.hadProj = live
        \\  -- Still hers after the HUD icon, which `DrawHudMetroid` restores. A
        \\  -- quake moves the sprite and not the on-screen byte (01:$7A34), by
        \\  -- the timer's bit 2: that is phase 23's to grade, and allowed for here.
        \\  local qt = emu.read(AL.MC.quakeTimer, wram)
        \\  local qs = qt == 0 and 0 or ((qt & AL.MC.samusBit) ~= 0 and 1 or -1)
        \\  if sprx ~= onx or spry ~= ((ony + qs) & 0xFF) then emu.stop(122) end
        \\
        \\  local want = SPR_PARTS[id]
        \\  if want == nil or used ~= (want + iconParts + textParts) * 4 then emu.stop(123) end
        \\
        \\  if shownId ~= nil then
        \\    local oam = emu.memType.snesSpriteRam
        \\    local hi = emu.read(512, oam)
        \\    local wx = ((shownX + SPR_DX[shownId]) & 0xFF) - OAM_X_OFS + WIN_LEFT
        \\    local wy = ((shownY + SPR_DY[shownId]) & 0xFF) - OAM_Y_OFS + BAND_TOP
        \\    -- Her first part follows the save text's, when there was any.
        \\    local e = shownText
        \\    local hb = (hi >> ((e % 4) * 2)) & 3
        \\    if e >= 4 then hb = (emu.read(512 + e // 4, oam) >> ((e % 4) * 2)) & 3 end
        \\    if emu.read(e * 4, oam) ~= (wx & 0xFF) then emu.stop(124) end
        \\    if (hb & 1) ~= (wx >> 8) then emu.stop(124) end
        \\    if emu.read(e * 4 + 1, oam) ~= (wy & 0xFF) then emu.stop(124) end
        \\    if (hb & 2) ~= 0 then emu.stop(124) end
        \\    -- Step 24e: in front (OBJ priority 2) or behind (0) as her screen's
        \\    -- transition word says, which is 00:$3ED5 and 01:$4BA1. Taken from
        \\    -- the ROM when the frame was composed, like the rest of `shown`.
        \\    if ((emu.read(e * 4 + 3, oam) >> 4) & 3) ~= PRI_SHOWN then emu.stop(20) end
        \\    -- 1.0 Step 25: on OBP1, palette 1, while she is in acid or in
        \\    -- i-frames (01:$4DFC-$4E0D, then $4B95), and on OBP0 otherwise.
        \\    if ((emu.read(e * 4 + 3, oam) >> 1) & 7) ~= PAL_SHOWN then emu.stop(149) end
        \\  end
        \\  local cell = (((samy >> 8) & 0xF) << 4) | ((samx >> 8) & 0xF)
        \\  PRI_SHOWN = PRI_BEHIND[emu.read(RAM_MAPIDX, wram) * 256 + cell] and 0 or 2
        \\  PAL_SHOWN = (emu.read(AL.MC.acidContact, wram) ~= 0 or emu.read(AL.MC.invuln, wram) ~= 0) and 1 or 0
        \\  oamShown, shownX, shownY, shownId, shownText = used, sprx, spry, id, textParts
        \\  return id
        \\end
        \\
        \\-- Phase 27's tally of the scroll -- how many frames it lasted, how many
        \\-- of them moved Samus's drawn position, and how many drew anything at
        \\-- all -- is a **global on purpose**. This chunk is at Lua's ceiling of
        \\-- 200 locals in a main function, and Step 17's `local scroll` was the
        \\-- one over: the script stopped compiling, `emu.stop` never ran, and the
        \\-- testrunner reported a timeout, which reads as a hung cart rather than
        \\-- as a broken fixture. Anything added here from now on has the same
        \\-- ceiling to clear.
        \\
        \\-- Which of `CROSSINGS` is being driven, and the lever that starts one.
        \\-- The door index is what `RunPendingTransition` acts on; the direction
        \\-- is what chooses the arm that draws the incoming edge, and nothing
        \\-- else reads it. A crossing driven without it runs the script,
        \\-- re-seats the room, takes the right number of frames -- and draws
        \\-- nothing, because 00:$2938 is where an unrecognised direction goes.
        \\local crossing = 0
        \\local function startCrossing(n)
        \\  crossing = n
        \\  emu.write(RAM_DOORIDX, DOOR_INDEX & 0xFF, wram)
        \\  emu.write(RAM_DOORIDX + 1, (DOOR_INDEX >> 8) & 0xFF, wram)
        \\  emu.write(RAM_TRANSDIR, CROSSINGS[n].dir, wram)
        \\end
        \\
        \\-- The incoming edge, against the ROM's own map data. Each strip is
        \\-- sixteen metatiles stepping 16 pixels along the crossing's axis, and
        \\-- each metatile is four tilemap slots; which room a metatile comes
        \\-- from is decided by its own coordinates, exactly as `StreamOne`
        \\-- decides it. EXPAND holds those rooms; this holds only the
        \\-- addressing, which is the part being asserted. `expand` and `code`
        \\-- default to phase 8's; phase 23 passes each gate's own room. The
        \\-- return is the slots compared, so a caller can refuse a vacuous pass.
        \\local function checkEdge(c, camx, camy, expand, code)
        \\  expand, code = expand or EXPAND, code or 137
        \\  local n = 0
        \\  for _, st in ipairs(c.starts) do
        \\    for k = 0, 15 do
        \\      local step = k * 16
        \\      local sx = (camx + st[1] + (c.axis == 0 and step or 0)) & 0xFFF
        \\      local sy = (camy + st[2] + (c.axis == 1 and step or 0)) & 0xFFF
        \\      local e = expand[(((sy >> 8) & 0xF) << 4) | ((sx >> 8) & 0xF)]
        \\      if e ~= nil then
        \\        local r0, c0 = ((sy >> 4) & 0xF) * 2, ((sx >> 4) & 0xF) * 2
        \\        for dr = 0, 1 do
        \\          for dc = 0, 1 do
        \\            local slot = (r0 + dr) * 32 + (c0 + dc)
        \\            if emu.read(RAM_TILEMAP + slot * 2, wram) ~= e[slot + 1] then emu.stop(code) end
        \\            n = n + 1
        \\          end
        \\        end
        \\      end
        \\    end
        \\  end
        \\  return n
        \\end
        \\
        \\local function tick()
        \\  since = since + 1
        \\  local cell = emu.read(RAM_CELL, wram)
        \\  local camx, camy = rd16(RAM_CAMX, wram), rd16(RAM_CAMY, wram)
        \\  local samx, samy = rd16(RAM_SAMX, wram), rd16(RAM_SAMY, wram)
        \\  local pose = emu.read(RAM_POSE, wram)
        \\  local jumpArc = emu.read(RAM_JUMPARC, wram)
        \\
        \\  if emu.read(RAM_UNHANDLED, wram) ~= 0 then emu.stop(78) end
        \\  -- The frame counter's phase, decided by the engine on the one
        \\  -- frame that can see it and reported here. See `bug_tracker.md`,
        \\  -- 2026-09-09: the number of NMIs between the record's seed and the
        \\  -- first frame of `MainLoop` is not observable from outside, and an
        \\  -- extra one inverts every walk step for the rest of the run.
        \\  if emu.read(RAM_FRAMEPHASE, wram) ~= 0 then emu.stop(16) end
        \\  local sprId = checkSprite(camx, camy, samx, samy)
        \\
        \\  -- The blocked edge, as an invariant rather than an event: while the
        \\  -- camera is still on the boot screen it may never pass that screen's
        \\  -- clamp, whatever is driving it.
        \\  --
        \\  -- Which screen it is on has to come from the camera's own screen
        \\  -- nibbles rather than from `!Cell`. `LatchCell` runs at the top of
        \\  -- `HandleCamera`, before the camera moves, so `!Cell` is a frame
        \\  -- behind: on the frame the pixel byte wraps past a boundary the
        \\  -- camera is already in the neighbour and `!Cell` still says it is not.
        \\  local camCell = (((camy >> 8) & 0xF) << 4) | ((camx >> 8) & 0xF)
        \\  if camCell == CELL then
        \\    if ((camx & 0xFF) - WALL_CLAMP) * WALL_SIGN > 0 then emu.stop(70) end
        \\  end
        \\
        \\  if phase == 1 then
        \\    -- The fall she starts in. The seed drops her; the collision data has
        \\    -- to stop her, on the screen she started on.
        \\    if (samy & 0xF00) ~= startScreenY then emu.stop(62) end
        \\    if pose == POSE_STAND and samy == prevY then still = still + 1 else still = 0 end
        \\    prevY = samy
        \\    if still >= STILL_FOR then
        \\      if cell ~= CELL then emu.stop(71) end
        \\      groundY, groundCamY = samy, camy
        \\      sawStandId = sprId
        \\      expectVisible(camx, camy, samx, samy)
        \\      compareAt(SCREEN, camx, camy, 20, 60)
        \\      enter(2, JUMP_BTN)
        \\    elseif since > GIVE_UP then emu.stop(61) end
        \\
        \\  elseif phase == 2 then
        \\    -- Jump, held all the way to the top, so the whole ascent runs: six
        \\    -- frames of the start pose, then two pixels a frame while the
        \\    -- counter climbs to JUMP_BASE, and only then the converted arc, one
        \\    -- speed a frame until it runs out and she starts falling.
        \\    --
        \\    -- Holding to the top is the point. Releasing early skips to the tail
        \\    -- of the arc, and a gate that released as soon as she was airborne
        \\    -- passed with the whole arc zeroed out - the linear part alone had
        \\    -- already lifted her further than the test asked for. `linearTop` is
        \\    -- the answer to that: the rise at the moment the counter reaches the
        \\    -- table is what the linear part did on its own, and the arc has to
        \\    -- beat it.
        \\    if pose == POSE_NJUMPSTART then sawStart = true end
        \\    if pose == POSE_JUMP then sawJump = true; sawJumpId = sprId end
        \\    local up = (groundY - samy) & 0xFFF
        \\    if up < 0x800 and up > apex then apex = up end
        \\    if linearTop == nil and jumpArc >= JUMP_BASE then linearTop = apex end
        \\    if camApex == nil or camy < camApex then camApex = camy end
        \\    if pose == POSE_FALL then
        \\      if linearTop == nil or apex <= linearTop then emu.stop(19) end
        \\      if apex < JUMP_RISE then emu.stop(63) end
        \\      enter(3, nil)
        \\    elseif since > GIVE_UP then emu.stop(63) end
        \\
        \\  elseif phase == 3 then
        \\    -- Released. Gravity is the fall arc, and the floor is the same floor.
        \\    if camApex == nil or camy < camApex then camApex = camy end
        \\    if pose == POSE_STAND and samy == prevY then still = still + 1 else still = 0 end
        \\    prevY = samy
        \\    if still >= STILL_FOR then
        \\      if not (sawStart and sawJump) then emu.stop(64) end
        \\      if samy ~= groundY then emu.stop(65) end
        \\      if delta(groundCamY, camApex) < CAM_RISE then emu.stop(68) end
        \\      enter(4, WALL_DIR)
        \\    elseif since > GIVE_UP then emu.stop(63) end
        \\
        \\  elseif phase == 4 then
        \\    -- Walk into the blocked edge. Two things can stop her and either is
        \\    -- the right answer: the terrain, or the camera's clamp. On this
        \\    -- screen it is the terrain - she is walled in a few pixels along -
        \\    -- so the clamp is asserted above, as a line the camera never
        \\    -- crosses, rather than here as a place it reaches. Which of the two
        \\    -- happens is a property of the boot screen's shape, so the test
        \\    -- accepts either instead of assuming one. Step 12a could assume,
        \\    -- because the d-pad drove the camera directly and the terrain had no
        \\    -- say in it.
        \\    expectHeld(WALL_BIT, since)
        \\    checkWalk(samx)
        \\    checkCamStep(camx)
        \\    walkIds[emu.read(RAM_FACING, wram)] = sprId
        \\    if (camx & 0xFF) == WALL_CLAMP then hitWall = true end
        \\    if since > 2 and samx == prevWallX then
        \\      wallStill = wallStill + 1
        \\      if wallStill >= STILL_FOR then hitWall = true end
        \\    else
        \\      wallStill = 0
        \\    end
        \\    prevWallX = samx
        \\    if since >= WALL_HOLD then
        \\      if not hitWall then emu.stop(69) end
        \\      if cell ~= CELL then emu.stop(71) end
        \\      -- Standing and jumping are different sprites. If they were not,
        \\      -- every pose could be drawing whatever the dispatch fell through
        \\      -- to and the picture would still look like Samus.
        \\      if sawStandId == nil or sawJumpId == nil then emu.stop(125) end
        \\      if sawStandId == sawJumpId then emu.stop(125) end
        \\      enter(5, OPEN_DIR)
        \\    end
        \\
        \\  elseif phase == 5 then
        \\    -- Walk into the opening. This has to *scroll* across the boundary:
        \\    -- the camera carries into the neighbour a pixel at a time, and the
        \\    -- tilemap is rebuilt column by column behind it.
        \\    expectHeld(OPEN_BIT, since)
        \\    checkWalk(samx)
        \\    checkCamStep(camx)
        \\    checkGuide(camx, samx)
        \\    walkIds[emu.read(RAM_FACING, wram)] = sprId
        \\    if cell ~= CELL then
        \\      if cell ~= CELL_AFTER_OPEN then emu.stop(73) end
        \\      enter(6, OPEN_DIR)
        \\    elseif since > GIVE_UP then emu.stop(72) end
        \\
        \\  elseif phase == 6 then
        \\    -- Keep walking until the whole window is inside the neighbour, so a
        \\    -- render of that one screen can say what it should look like.
        \\    expectHeld(OPEN_BIT, since)
        \\    checkWalk(samx)
        \\    checkCamStep(camx)
        \\    checkGuide(camx, samx)
        \\    if cell ~= CELL_AFTER_OPEN then emu.stop(73) end
        \\    local px, py = camx & 0xFF, camy & 0xFF
        \\    if px >= WIN_MIN_X and px <= WIN_MAX_X and py >= WIN_MIN_Y and py <= WIN_MAX_Y then
        \\      enter(7, nil)
        \\    elseif since > GIVE_UP then emu.stop(75) end
        \\
        \\  elseif phase == 7 then
        \\    -- Input released. The engine uploads the tilemap and writes the
        \\    -- scroll registers from the NMI, so the frame on the screen trails
        \\    -- the camera variable this reads; letting it come to a stop is what
        \\    -- makes the comparison about the picture rather than about that lag.
        \\    if camx == prevCam and camy == prevCamY then still = still + 1 else still = 0 end
        \\    prevCam, prevCamY = camx, camy
        \\    if still >= STILL_FOR then
        \\      if cell ~= CELL_AFTER_OPEN then emu.stop(73) end
        \\      if not guideLocked then emu.stop(18) end
        \\      expectVisible(camx, camy, samx, samy)
        \\      compareAt(SCREEN_AFTER, camx, camy, 80, 120)
        \\      if rose[WALL_BIT] ~= 1 or rose[OPEN_BIT] ~= 1 then emu.stop(77) end
        \\      -- The two walks went opposite ways, so both facings were drawn
        \\      -- and they must not be the same sprite. A dispatch that ignored
        \\      -- the facing byte entirely would pass everything else here.
        \\      if walkIds[0] == nil or walkIds[1] == nil then emu.stop(126) end
        \\      if walkIds[0] == walkIds[1] then emu.stop(126) end
        \\      -- Everything above is Phase 0a's cart. What follows is the room
        \\      -- transition, and it is driven rather than walked into: the
        \\      -- triggers in `HandleCamera` are assembled but disarmed until the
        \\      -- transition's *duration* is a computed quantity, so the gate
        \\      -- hands the engine a door index the way `room.spawn` hands the
        \\      -- Game Boy two operand bytes. Same lever, other machine.
        \\      warpFrom = {{ camx = camx, camy = camy, samx = samx, samy = samy }}
        \\      startCrossing(1)
        \\      enter(8, nil)
        \\    elseif since > GIVE_UP then emu.stop(75) end
        \\
        \\  elseif phase == 8 then
        \\    -- `RunPendingTransition` picks the index up on the next pass of the
        \\    -- main loop and runs the script, which ends by clearing it.
        \\    if rd16(RAM_DOORIDX, wram) ~= 0 then
        \\      if since > GIVE_UP then emu.stop(130) end
        \\      return
        \\    end
        \\    -- **How long it took, which is the other half of the port and the
        \\    -- half a re-seat assertion cannot see.** The interpreter is
        \\    -- frame-paced: a frame per opcode (00:$26D1), `ceil(len/64)` per
        \\    -- VRAM transfer because the vblank queue drains 64 bytes a frame
        \\    -- (00:$2BC7), and four frames plus a 34-step fade for `FADEOUT`.
        \\    -- TRANS_FRAMES is what a Game Boy spends on this exact script,
        \\    -- computed by `src/transition.zig` and graded there against a
        \\    -- running one.
        \\    --
        \\    -- No off-by-one, and it is worth saying why rather than leaving it
        \\    -- to look like luck. This hook runs at the top of `MainLoop`,
        \\    -- *ahead* of `RunPendingTransition`, so the tick that wrote the
        \\    -- index is also the tick before that same frame's pacer picks it
        \\    -- up: the frame the write happens on is the transition's first.
        \\    -- `since` is therefore the count of frames the transition owned,
        \\    -- and it has to equal the Game Boy's exactly -- 2% would be a
        \\    -- tenth of a frame here.
        \\    if since ~= CROSSINGS[crossing].frames then emu.stop(136) end
        \\    -- The map bank and the cell are the warp's two operands, and the
        \\    -- cell is the position byte repacked: (row << 4) | col.
        \\    if emu.read(RAM_MAPIDX, wram) ~= WARP_BANK then emu.stop(131) end
        \\    if cell ~= (WARP_ROW * 16 + WARP_COL) then emu.stop(132) end
        \\    -- **The re-seat, which is the assertion this phase exists for.** A
        \\    -- position is `screen << 8 | pixel`, and a warp replaces the screen
        \\    -- half of the camera and of Samus and keeps the pixel half. That is
        \\    -- not our rule: it is what 00:$2909-$2912 does, four byte stores
        \\    -- into the screen halves of $FFC8-$FFCB and $FFC0-$FFC3 and nothing
        \\    -- into the pixel ones, and it is why the movie's own crossing takes
        \\    -- her from $07F3,$0784 to $03F3,$0484 -- four nibbles changed and
        \\    -- two bytes kept.
        \\    if ((camx >> 8) & 0xF) ~= WARP_COL then emu.stop(133) end
        \\    if ((camy >> 8) & 0xF) ~= WARP_ROW then emu.stop(133) end
        \\    if ((samx >> 8) & 0xF) ~= WARP_COL then emu.stop(134) end
        \\    if ((samy >> 8) & 0xF) ~= WARP_ROW then emu.stop(134) end
        \\    -- And the half that must NOT have moved. Without this the check
        \\    -- above passes on an engine that threw the pixel away and wrote a
        \\    -- whole screen coordinate, which is the first thing a re-seat gets
        \\    -- wrong.
        \\    if (camx & 0xFF) ~= (warpFrom.camx & 0xFF) then emu.stop(135) end
        \\    if (camy & 0xFF) ~= (warpFrom.camy & 0xFF) then emu.stop(135) end
        \\    if (samx & 0xFF) ~= (warpFrom.samx & 0xFF) then emu.stop(135) end
        \\    if (samy & 0xFF) ~= (warpFrom.samy & 0xFF) then emu.stop(135) end
        \\    -- **And the picture, which is what the crossing is for.** The
        \\    -- incoming room is not copied in by the script -- no door script
        \\    -- in this ROM carries a tilemap `COPY` -- it is *drawn*, three
        \\    -- metatile columns at a time, by the arm of `WarpDraw` the
        \\    -- direction selects. STRIP is those columns expanded out of the
        \\    -- ROM's own map data, so this compares the buffer the engine's
        \\    -- collision reads against the room the Game Boy would have been
        \\    -- standing in.
        \\    checkEdge(CROSSINGS[crossing], camx, camy)
        \\    -- Hand the direction back before `TransitionCamera` can act on
        \\    -- it: the scroll is not what this phase grades, and leaving it
        \\    -- set would move the camera out from under every assertion above.
        \\    --
        \\    -- **The scroll is graded, since Step 17, but not here.** Letting it
        \\    -- run mid-test does not survive: the warp back replaces the screen
        \\    -- halves and keeps the pixel ones, so the pixels the drag added stay
        \\    -- added and phase 11's block test finds Samus standing somewhere
        \\    -- else (seen: exit 153). Phase 27 runs it at the end instead, where
        \\    -- nothing downstream can inherit the damage.
        \\    emu.write(RAM_TRANSDIR, 0, wram)
        \\    -- Then do it again the other way. The warp's operands are
        \\    -- absolute, so the second crossing lands in the same place from
        \\    -- the same camera -- what changes is the arm, and with it the
        \\    -- number of strips, their axis, and the frames they cost.
        \\    if crossing < #CROSSINGS then
        \\      warpFrom = {{ camx = camx, camy = camy, samx = samx, samy = samy }}
        \\      startCrossing(crossing + 1)
        \\      since = 0
        \\      return
        \\    end
        \\    -- The crossings are done. Hand the frame to B6.
        \\    enter(9, nil)
        \\
        \\  elseif phase == 9 then
        \\    -- **B6: the item pickup.** The lever is one byte: `enAI_itemOrb`
        \\    -- sets `itemCollected` when Samus touches the item, and there is
        \\    -- no item orb in this room -- so the gate writes the byte the AI
        \\    -- would have written and grades everything downstream of it. What
        \\    -- that leaves ungraded is named rather than implied: the AI
        \\    -- itself, and the four `enemy_getSamusCollisionResults` branches
        \\    -- that decide *whether* to write it.
        \\    if pickAt == nil then
        \\      -- The AI's own stores at 02:$4E6D-$4E7C, both of them: the item
        \\      -- number and the flag that says a collection has started.
        \\      emu.write(RAM_ITEMCOLLECTED, ITEM_NUMBER, wram)
        \\      emu.write(RAM_ITEMFLAG, 0xFF, wram)
        \\      pickAt = since
        \\      pickX, pickY = samx, samy
        \\      itemsBefore = emu.read(RAM_ITEMS, wram)
        \\      return
        \\    end
        \\    local ago = since - pickAt
        \\    if ago == 1 and emu.read(RAM_ITEMSTAGE, wram) == 0 then emu.stop(140) end
        \\    local bits = emu.read(RAM_ITEMS, wram)
        \\    if bits ~= itemsBefore then
        \\      -- **The four frames, which are measured and not assumed.** On
        \\      -- all four of the B11 recording's pickups the item bit lands
        \\      -- exactly four frames after Samus freezes, which is the four
        \\      -- `waitOneFrame`s at 00:$3734 and nothing else.
        \\      --
        \\      -- `ITEM_WAIT + 1` and not `ITEM_WAIT`, and the extra frame is
        \\      -- this gate's lever rather than the mechanism: the hook runs at
        \\      -- the *end* of a frame, so a byte written on tick T is first
        \\      -- seen by the `MainLoop` pass of tick T+1 -- which is the frame
        \\      -- the original's play handler first reaches 00:$372F on, after
        \\      -- the enemy pass that set it. Measured rather than assumed: the
        \\      -- probe that found it stopped with `200 + ago` and returned 205.
        \\      if gotAt == nil then
        \\        gotAt = ago
        \\        if ago ~= ITEM_WAIT + 1 then emu.stop(141) end
        \\        if bits ~= (itemsBefore | ITEM_MASK) then emu.stop(142) end
        \\      end
        \\    end
        \\    -- Samus is frozen for the whole jingle: the pose machine, the
        \\    -- streamer and the camera do not run on a pickup frame, and a
        \\    -- port that let them would show here as a pixel of drift.
        \\    if gotAt ~= nil and emu.read(RAM_ITEMSTAGE, wram) ~= 0 then
        \\      if samx ~= pickX or samy ~= pickY then emu.stop(143) end
        \\    end
        \\    -- **The far half of the handshake is the item object's, and there
        \\    -- is no item object here.** `ItemJingleDone` writes $03 into the
        \\    -- flag to say the sequence is over, and `enAI_itemOrb` is what
        \\    -- clears it as it deletes itself -- which is why the recording's
        \\    -- tails are 2, 3, 3 and 10 frames rather than one number. This
        \\    -- room has an empty spawn list, so the gate stands in for that
        \\    -- clear, and says so: **the delete arm of the AI is not graded by
        \\    -- this rung.** What is graded is everything up to it, including
        \\    -- that the engine reached $03 at all.
        \\    if emu.read(RAM_ITEMFLAG, wram) == 3 then
        \\      if ago < ITEM_WAIT + ITEM_JINGLE then emu.stop(144) end
        \\      emu.write(RAM_ITEMFLAG, 0, wram)
        \\      -- And `itemCollected` with it, which is the other half of
        \\      -- 02:$4E80's two stores. Without it the byte this gate wrote
        \\      -- is still sitting there when the stage returns to idle and the
        \\      -- cart collects the same Bomb again, forever -- measured, as a
        \\      -- probe reading `!ItemStage` back at 1 sixty frames into a
        \\      -- phase that thought it was watching the pose machine.
        \\      emu.write(RAM_ITEMCOLLECTED, 0, wram)
        \\      return
        \\    end
        \\    if gotAt ~= nil and emu.read(RAM_ITEMSTAGE, wram) == 0 then
        \\      if ago < ITEM_WAIT + ITEM_JINGLE then emu.stop(144) end
        \\      enter(10, JUMP_BTN)
        \\      return
        \\    end
        \\    if ago > ITEM_WAIT + ITEM_JINGLE + 600 then
        \\      if gotAt == nil then emu.stop(141) end
        \\      emu.stop(145)
        \\    end
        \\
        \\  elseif phase == 10 then
        \\    -- **What the bit is for.** `PoseMorph` at 00:$1721 lets A start a
        \\    -- ball jump only when `itemBit_springBall` is set (`BIT 4,A` at
        \\    -- $1727). Until Step 24 this phase said the Bomb's, and so did the
        \\    -- engine, so a cart holding the Bomb jumped on A. Three tries, in
        \\    -- this order, because a fixture that only shows the branch firing
        \\    -- does not show *what* gates it: `!Items` cleared, where the ball
        \\    -- must keep rolling; the Bomb phase 9 gave, where it must still
        \\    -- roll; and the Bomb with Spring Ball's bit, where it must jump.
        \\    if bombTry == nil then
        \\      bombTry = 0
        \\      bombBits = emu.read(RAM_ITEMS, wram)
        \\      emu.write(RAM_ITEMS, 0, wram)
        \\      bombAt = since
        \\    end
        \\    -- Read before writing, or the lever below would erase the answer.
        \\    local held = since - bombAt
        \\    local pose = emu.read(RAM_POSE, wram)
        \\    if pose == POSE_BALLFALL then dbgFall = 2 end
        \\    if pose == POSE_MORPH then dbgMorph = 4 end
        \\    if dbgY ~= nil and samy ~= dbgY then dbgMoved = 1 end
        \\    dbgY = samy
        \\    if pose == POSE_MORPH and dbgPrev == POSE_MORPH then dbgGround = 8 end
        \\    dbgPrev = pose
        \\    if bombTry == 0 then
        \\      if pose == POSE_BALLJUMP then emu.stop(147) end
        \\      if held > BOMB_TRY then
        \\        bombTry = 1
        \\        emu.write(RAM_ITEMS, bombBits, wram)
        \\        bombAt = since
        \\      end
        \\    elseif bombTry == 1 then
        \\      if pose == POSE_BALLJUMP then emu.stop(148) end
        \\      if held > BOMB_TRY then
        \\        bombTry = 2
        \\        emu.write(RAM_ITEMS, bombBits | SPRING_MASK, wram)
        \\        bombAt = since
        \\      end
        \\    else
        \\      if pose == POSE_BALLJUMP then
        \\        -- Back to what the pickup gave, so no later phase holds a
        \\        -- Spring Ball the slice never collects.
        \\        emu.write(RAM_ITEMS, bombBits, wram)
        \\        enter(11, "up")
        \\        return
        \\      end
        \\      if held > BOMB_TRY then emu.stop(146) end
        \\    end
        \\    -- **Two levers, and both isolate the branch rather than assist
        \\    -- it.**
        \\    --
        \\    -- The morph is forced only when she is not already in a ball
        \\    -- pose, and that qualification was measured rather than reasoned:
        \\    -- forcing it *every* frame hung her in the air forever, because
        \\    -- `poseFunc_morphBall` off the ground writes $08 and returns
        \\    -- without moving her -- the falling is `poseFunc_ballFall`'s job,
        \\    -- and overwriting the pose meant that handler never ran. The
        \\    -- probe read poses $05 and $08 and nothing else.
        \\    --
        \\    -- `!DownSpeed` is cleared because a landing at two pixels a frame
        \\    -- bounces into $06 *without* the Bomb (00:$1740), which is the
        \\    -- one other way into this pose and would make the ungated half
        \\    -- read as a pass.
        \\    if pose ~= POSE_MORPH and pose ~= POSE_BALLJUMP and pose ~= POSE_BALLFALL then
        \\      emu.write(RAM_POSE, POSE_MORPH, wram)
        \\    end
        \\    emu.write(RAM_DOWNSPEED, 0, wram)
        \\
        \\  elseif phase == 11 then
        \\    -- **B5's terrain half: the block under her feet.** The lever is a
        \\    -- slot, which is the three bytes `destroyRespawningBlock` writes,
        \\    -- and everything downstream of it is graded: the counter's six
        \\    -- dispatches, the tiles each arm draws, and -- the one that
        \\    -- matters -- whether the engine's *collision* follows the picture.
        \\    --
        \\    -- What that leaves ungraded is named rather than implied:
        \\    -- `HitBlock`, which decides *whether* a tile is a block, and
        \\    -- `DestroyRespawningBlock`, which chooses the slot. Both need a
        \\    -- projectile, and the projectile is Step 12b's.
        \\    if blkAt == nil then
        \\      -- The threshold the classification will compare against, before
        \\      -- anything else: it comes from the door script the cart booted
        \\      -- on, through the ROM's own table, and the engine takes no part
        \\      -- in producing the number this is checked against.
        \\      if emu.read(RAM_SOLIDBEAM, wram) ~= BEAM_THRESHOLD then emu.stop(150) end
        \\      -- She has to be standing on something for any of this to mean
        \\      -- anything, and phase 10 leaves her in the ball -- so this phase
        \\      -- is entered holding Up, which is `poseFunc_morphBall`'s own way
        \\      -- out, and waits for her to land and stand.
        \\      if emu.read(RAM_POSE, wram) ~= POSE_STAND then
        \\        if since > 240 then emu.stop(153) end
        \\        return
        \\      end
        \\      hold = nil
        \\      blkHoldY, blkHoldX = samy, samx
        \\      -- `CollideBottom`'s foot probe: the tile she is actually resting
        \\      -- on, by the same arithmetic the engine uses to ask about it.
        \\      local by = (samy + PROBE_Y) & 0xFF
        \\      local bx = (samx + PROBE_X) & 0xFF
        \\      local row = ((by - OAM_Y_OFS) & 0xF8) >> 3
        \\      local col = ((bx - OAM_X_OFS) & 0xF8) >> 3
        \\      blkSlot = (row * 32 + col) & 0xFFDE
        \\      emu.write(RAM_BLOCKS + 1, by, wram)
        \\      emu.write(RAM_BLOCKS + 2, bx, wram)
        \\      emu.write(RAM_BLOCKS, 1, wram)
        \\      blkAt = since
        \\      return
        \\    end
        \\    local counter = emu.read(RAM_BLOCKS, wram)
        \\    -- 01:$5739's gate, which is recorded rather than followed. It must
        \\    -- not fire before the reform -- nothing else in the routine reaches
        \\    -- it -- and it must fire *on* the reform, because Samus is pinned
        \\    -- to the pixel the block is coming back at and her i-frames are
        \\    -- down. A recording nothing ever reaches is dead code with a
        \\    -- comment on it.
        \\    --
        \\    -- `counter ~= 0` is what keeps the two halves apart: the reform's
        \\    -- first act is to free the slot, so the frame the branch fires on
        \\    -- is the frame the counter reads zero, and without this guard the
        \\    -- "must not fire early" half fires on it.
        \\    local crush = emu.read(RAM_BLKCRUSH, wram)
        \\    if counter ~= 0 and not blkSawBack and crush ~= 0 then emu.stop(158) end
        \\    -- Which pictures were up at which counter. Recorded rather than
        \\    -- asserted on the spot, because the hook runs at the end of a
        \\    -- frame and the arm that drew ran inside it.
        \\    if counter ~= 0 then
        \\      if blkIsRun(blkSlot, BLK_TILE_A) then blkSeen[BLK_TILE_A] = counter end
        \\      if blkIsRun(blkSlot, BLK_TILE_B) then blkSeen[BLK_TILE_B] = counter end
        \\    end
        \\    if blkIsGone(blkSlot) then blkSawGone = true end
        \\    -- **The collision change, which is what this phase is for.** She is
        \\    -- pinned to the pixel she was standing on, so nothing about her
        \\    -- position changes across the whole window; the only thing that
        \\    -- changes is whether the engine thinks there is a floor there.
        \\    local pose = emu.read(RAM_POSE, wram)
        \\    if blkSawGone and not blkSawBack and pose ~= POSE_STAND then blkSawFall = true end
        \\    if not blkSawBack then
        \\      emu.write(RAM_SAMY, blkHoldY & 0xFF, wram)
        \\      emu.write(RAM_SAMY + 1, (blkHoldY >> 8) & 0xFF, wram)
        \\      emu.write(RAM_SAMX, blkHoldX & 0xFF, wram)
        \\      emu.write(RAM_SAMX + 1, (blkHoldX >> 8) & 0xFF, wram)
        \\    end
        \\    -- The counter is 253 frames long and 233 of them are the block
        \\    -- sitting there gone. **The clock is wound on rather than waited
        \\    -- out** -- once the empty frame has been seen and the fall with
        \\    -- it, the counter is set to one short of the first crack coming
        \\    -- back, and the last three dispatches run at their own pace.
        \\    if blkSawGone and blkSawFall and counter > BLK_EMPTY_AT and counter < BLK_CRACK3 then
        \\      emu.write(RAM_BLOCKS, BLK_CRACK3 - 1, wram)
        \\      return
        \\    end
        \\    if counter == 0 and blkSawGone then
        \\      -- The slot freed itself, which is the reform's own first act.
        \\      if not blkIsRun(blkSlot, BLK_TILE_SOLID) then emu.stop(154) end
        \\      if not blkSawFall then emu.stop(153) end
        \\      if blkSeen[BLK_TILE_A] == nil or blkSeen[BLK_TILE_B] == nil then emu.stop(152) end
        \\      if crush == 0 then emu.stop(158) end
        \\      blkSawBack = true
        \\    end
        \\    if blkSawBack then
        \\      -- Released. The floor is back under the pixel she never left, so
        \\      -- she must come to rest on it -- and this is the half of the
        \\      -- assertion the picture cannot give: the tiles were already
        \\      -- checked above, and this is the collision agreeing with them.
        \\      if pose == POSE_STAND then
        \\        enter(12, nil)
        \\        return
        \\      end
        \\      if since - blkAt > 300 then emu.stop(156) end
        \\      return
        \\    end
        \\    if since - blkAt > 400 then
        \\      if not blkSawGone then emu.stop(151) end
        \\      if not blkSawFall then emu.stop(153) end
        \\      emu.stop(155)
        \\    end
        \\
        \\  elseif phase == 12 then
        \\    -- The eviction. A slot whose distance from the scroll has high
        \\    -- nibble $C vertically is off the screen for good: the slot frees
        \\    -- itself and **draws nothing on the way out**, which is the half
        \\    -- worth asserting -- a version that fell through to the counter
        \\    -- dispatch would put a crack somewhere in the room.
        \\    if evictAt == nil then
        \\      local scrollY = (emu.read(RAM_CAMY, wram) - GB_SCROLL_Y_BIAS) & 0xFF
        \\      emu.write(RAM_BLOCKS + BLK_SIZE + 1, (scrollY + BLK_EVICT_Y) & 0xFF, wram)
        \\      emu.write(RAM_BLOCKS + BLK_SIZE + 2, emu.read(RAM_BLOCKS + 2, wram), wram)
        \\      emu.write(RAM_BLOCKS + BLK_SIZE, 1, wram)
        \\      evictAt = since
        \\      return
        \\    end
        \\    if emu.read(RAM_BLOCKS + BLK_SIZE, wram) ~= 0 then
        \\      if since - evictAt > 4 then emu.stop(157) end
        \\      return
        \\    end
        \\    -- It went without drawing: the block Samus is standing on is still
        \\    -- the four solid tiles phase 11 left, and the evicted slot never
        \\    -- reached an arm that writes.
        \\    if not blkIsRun(blkSlot, BLK_TILE_SOLID) then emu.stop(157) end
        \\    if emu.read(RAM_POSE, wram) ~= POSE_STAND then emu.stop(157) end
        \\    enter(13, nil)
        \\
        \\  elseif phase == 13 then
        \\    -- **B5's projectile half: a shot, and the block it breaks.**
        \\    --
        \\    -- The lever here is not a poke. Every phase above this one writes
        \\    -- the byte the mechanism would have written and grades what
        \\    -- happens next, because nothing on the cart could reach it; this
        \\    -- one presses the fire button, which is what Step 12b added. So
        \\    -- the first assertion is that the array is *empty* before the
        \\    -- press: a cart that shot by itself would otherwise pass.
        \\    if shot.at == nil then
        \\      if liveProj() ~= nil then emu.stop(160) end
        \\      -- She has to be standing: `samus_possibleShotDirections` allows
        \\      -- nothing at all in some poses and a bomb in the ball's, and
        \\      -- phase 12 leaves her standing on the block it put back.
        \\      if emu.read(RAM_POSE, wram) ~= POSE_STAND then
        \\        if since > 240 then emu.stop(160) end
        \\        return
        \\      end
        \\      -- No direction is held, so the shot goes the way she faces --
        \\      -- 01:$4EC3's own fallback, and the only branch of the direction
        \\      -- resolution a fixture can reach without a d-pad.
        \\      shot.dir = (emu.read(RAM_FACING, wram) ~= 0) and 1 or 2
        \\      hold = B5.fire
        \\      shot.at = since
        \\      return
        \\    end
        \\    hold = nil
        \\    local ago = since - shot.at
        \\    if shot.slot == nil then
        \\      shot.slot = liveProj()
        \\      if shot.slot == nil then
        \\        -- The pad is published a frame behind, exactly as phase 9's
        \\        -- four-frame wait is a frame behind for the same reason.
        \\        if ago > 4 then emu.stop(161) end
        \\        return
        \\      end
        \\      if emu.read(shot.slot + B5.tDir, wram) ~= shot.dir then emu.stop(162) end
        \\      -- Put a block in front of it, sixteen pixels along its path.
        \\      -- Tile ids $00-$03 are respawning blocks *whatever* their
        \\      -- collision byte says (01:$5168), which is the one arm of the
        \\      -- classification that needs nothing from the tileset -- so the
        \\      -- phase does not depend on what the boot room is made of.
        \\      --
        \\      -- The position comes off the projectile the cart just made.
        \\      -- That is a lever and not an oracle: what is being graded is
        \\      -- that the shot destroys the block and dies, and placing the
        \\      -- block where the shot is going is how the phase gets to ask.
        \\      local py = (emu.read(shot.slot + B5.tY, wram) + B5.hitBias) & 0xFF
        \\      local px = (emu.read(shot.slot + B5.tX, wram) + B5.hitBias) & 0xFF
        \\      if shot.dir == 1 then px = (px + 16) & 0xFF else px = (px - 16) & 0xFF end
        \\      local row = ((py - OAM_Y_OFS) & 0xF8) >> 3
        \\      local col = ((px - OAM_X_OFS) & 0xF8) >> 3
        \\      shot.blk = (row * 32 + col) & 0xFFDE
        \\      for k = 0, 3 do
        \\        local o = (k < 2) and (shot.blk + k) or (shot.blk + 30 + k)
        \\        emu.write(RAM_TILEMAP + o * 2, BLK_TILE_SOLID + k, wram)
        \\      end
        \\      return
        \\    end
        \\    -- It flies, and the terrain sample happens on alternate frames --
        \\    -- 01:$52A0's `frameCounter & 1` -- so the block may take two
        \\    -- frames longer to go than the geometry alone would say.
        \\    if emu.read(shot.slot + B5.tType, wram) ~= B5.none then
        \\      if ago > 40 then emu.stop(163) end
        \\      return
        \\    end
        \\    -- The projectile is gone. It must have been the block that took
        \\    -- it, which is a slot in the block array holding the tile it was
        \\    -- aimed at -- `destroyRespawningBlock`'s own three bytes.
        \\    local found = false
        \\    for i = 0, 15 do
        \\      if emu.read(RAM_BLOCKS + i * BLK_SIZE, wram) ~= 0 then found = true end
        \\    end
        \\    if not found then emu.stop(164) end
        \\    if not blkIsRun(shot.blk, BLK_TILE_SOLID) and not blkIsRun(shot.blk, BLK_TILE_A)
        \\      and not blkIsRun(shot.blk, BLK_TILE_B) and not blkIsGone(shot.blk) then
        \\      emu.stop(164)
        \\    end
        \\    -- And nothing on this cart may have reached the bomb arms.
        \\    if emu.read(B5.unhandled, wram) ~= 0xFF then emu.stop(166) end
        \\    enter(14, nil)
        \\
        \\  elseif phase == 14 then
        \\    -- **And a shot into an enemy.** There is no enemy in this room --
        \\    -- phase 9 says so and its own lever exists because of it -- so the
        \\    -- slot is filled by hand. Every field the hitbox test and the
        \\    -- damage pass read is written, because an omitted one is a zero
        \\    -- that means something: status $00 is *active*, and a drop type or
        \\    -- an explosion flag left over would send the pass down another arm.
        \\    --
        \\    -- `B5.enTotal` is written too, and it is not optional: the count
        \\    -- is what ends `processEnemies`, not the end of the array, so a
        \\    -- slot written without it is a slot the pass never walks.
        \\    -- **First: a contact nobody claims has to survive the frame.**
        \\    -- `enemy_getDamagedOrGiveDrop` is the only thing that transfers the
        \\    -- four collision bytes and clears them, and it does that per
        \\    -- *enemy*, for the slot the contact names. The port used to clear
        \\    -- them unconditionally at the end of every `HandleEnemies` instead
        \\    -- -- a stand-in from Step 10, when the real routine was not ported
        \\    -- -- and with both in place a hit recorded on one of the enemy
        \\    -- pass's idle frames was wiped before any pass could act on it.
        \\    -- The record here names a slot offset nothing has, so no enemy can
        \\    -- legitimately consume it; anything that clears it is clearing it
        \\    -- on a timer.
        \\    if shot.keepAt == nil then
        \\      emu.write(B5.collWeapon, 0x20, wram)
        \\      emu.write(B5.collEnemy, 0xFE, wram)
        \\      emu.write(B5.collEnemy + 1, 0xFF, wram)
        \\      shot.keepAt = since
        \\      return
        \\    end
        \\    if since - shot.keepAt < 5 then return end
        \\    if shot.kept == nil then
        \\      if emu.read(B5.collWeapon, wram) ~= 0x20 then emu.stop(169) end
        \\      emu.write(B5.collWeapon, 0xFF, wram)
        \\      emu.write(B5.collEnemy, 0xFF, wram)
        \\      emu.write(B5.collEnemy + 1, 0xFF, wram)
        \\      shot.kept = true
        \\      return
        \\    end
        \\    if shot.enAt == nil then
        \\      if liveProj() ~= nil then emu.stop(160) end
        \\      if emu.read(RAM_POSE, wram) ~= POSE_STAND then
        \\        if since > 240 then emu.stop(160) end
        \\        return
        \\      end
        \\      shot.dir = (emu.read(RAM_FACING, wram) ~= 0) and 1 or 2
        \\      hold = B5.fire
        \\      shot.enAt = since
        \\      shot.slot = nil
        \\      return
        \\    end
        \\    hold = nil
        \\    local ago = since - shot.enAt
        \\    if shot.slot == nil then
        \\      shot.slot = liveProj()
        \\      if shot.slot == nil then
        \\        if ago > 4 then emu.stop(161) end
        \\        return
        \\      end
        \\      -- Where the shot will be in a few frames, in camera space,
        \\      -- with the enemy's own hitbox record centred on it.
        \\      local py = (emu.read(shot.slot + B5.tY, wram) + B5.hitBias) & 0xFF
        \\      local px = (emu.read(shot.slot + B5.tX, wram) + B5.hitBias) & 0xFF
        \\      if shot.dir == 1 then px = (px + 12) & 0xFF else px = (px - 12) & 0xFF end
        \\      local scrollY = (emu.read(RAM_CAMY, wram) - GB_SCROLL_Y_BIAS) & 0xFF
        \\      local scrollX = (emu.read(RAM_CAMX, wram) - B5.scrollXBias) & 0xFF
        \\      local base = B5.slots
        \\      emu.write(base + B5.y, (py - scrollY + B5.dy) & 0xFF, wram)
        \\      emu.write(base + B5.x, (px - scrollX + B5.dx) & 0xFF, wram)
        \\      emu.write(base + B5.sprite, B5.testId, wram)
        \\      -- The base attributes too, which the *draw* reads and the
        \\      -- collision does not: `drawEnemySprite_getInfo` composes the
        \\      -- flips out of +$04, +$05 and +$06 exclusive-ORed together, so a
        \\      -- slot written by hand without +$04 draws through whatever the
        \\      -- last room left there.
        \\      emu.write(base + B5.baseattr, 0, wram)
        \\      emu.write(base + B5.attr, 0, wram)
        \\      emu.write(base + B5.stun, 0, wram)
        \\      emu.write(base + B5.dirflags, 0, wram)
        \\      emu.write(base + B5.ice, 0, wram)
        \\      emu.write(base + B5.health, 0x20, wram)
        \\      emu.write(base + B5.maxhp, 0x20, wram)
        \\      emu.write(base + B5.drop, 0, wram)
        \\      emu.write(base + B5.explode, 0, wram)
        \\      emu.write(base + B5.flag, 4, wram)
        \\      emu.write(base + B5.status, 0, wram)
        \\      emu.write(B5.enTotal, 1, wram)
        \\      shot.hp = 0x20
        \\      return
        \\    end
        \\    local hp = emu.read(B5.slots + B5.health, wram)
        \\    if hp == shot.hp then
        \\      -- The enemy pass runs every other frame (02:$4131's own flag),
        \\      -- so the damage lands within a few frames of the contact and
        \\      -- not on it.
        \\      if ago > 60 then emu.stop(165) end
        \\      return
        \\    end
        \\    -- It was the power beam's damage, out of `weapon_damage`, and the
        \\    -- survivor took the stun 02:$4333 gives it.
        \\    if hp ~= shot.hp - B5.dmg then emu.stop(165) end
        \\    if emu.read(B5.slots + B5.stun, wram) ~= B5.stunHit then emu.stop(167) end
        \\    -- And the shot died on the enemy, which is the other half of what
        \\    -- `collision_projectileEnemies` returning carry means.
        \\    if emu.read(shot.slot + B5.tType, wram) ~= B5.none then emu.stop(168) end
        \\    if emu.read(B5.unhandled, wram) ~= 0xFF then emu.stop(166) end
        \\    enter(15, nil)
        \\
        \\  elseif phase == 15 then
        \\    -- **And the enemy is drawn.** Steps 9 and 10 filled the slots,
        \\    -- walked them, collided against them and damaged them, and until
        \\    -- Step 12d nothing put a single object in OAM for one: the enemy
        \\    -- metasprite set had been extracted and round-tripped since Step 4
        \\    -- and never shipped into the cart. A player saw enemies that hurt
        \\    -- and could not be seen, and no rung in this repository could tell
        \\    -- -- every one of them grades position, camera, pose or the
        \\    -- background, and the sprite check graded Samus alone.
        \\    --
        \\    -- The lever is the same one phase 14 used: a slot written by hand,
        \\    -- because the graded room's own spawn list is not the point. What
        \\    -- is asserted is everything downstream of it -- the blob resolved,
        \\    -- the pointer table indexed by the sprite id, the record walked,
        \\    -- and the parts landing where the enemy is with the window's two
        \\    -- biases applied.
        \\    if shot.drawAt == nil then
        \\      if liveProj() ~= nil then return end
        \\      -- Samus's parts and then the HUD icon's, which since Step 13b are
        \\      -- composed between her and the enemies.
        \\      local id = emu.read(RAM_SPRID, wram)
        \\      shot.samusParts = ((SPR_PARTS[id] or 0) + (hud.parts or 0)) * 4
        \\      -- **Hard against the left edge first, and that is the point.**
        \\      -- A part whose offset takes it left of column 0 wraps in eight
        \\      -- bits, exactly as the Game Boy's does -- so it lands near 248,
        \\      -- `PutObject` adds the window's net +40, and the result needs
        \\      -- OAM's ninth x bit. (No *unwrapped* column can: the play window
        \\      -- is 160 wide and starts at 48, so the widest an unclipped part
        \\      -- reaches is 199.) The phase then moves the same enemy to the
        \\      -- middle and requires the bit to be **gone**, which is the whole
        \\      -- test: nothing in this engine clears the high table -- `InitOam`
        \\      -- writes the low one and `ClearUnusedOam` only parks a y -- so a
        \\      -- `PutObject` that ORed its pair in left every slot that had ever
        \\      -- held a wrapped part stuck 256 pixels left for the rest of the
        \\      -- cart's life, and the sprites in it lost parts.
        \\      shot.enY, shot.enX = 0x50, 0x02
        \\      local base = B5.slots
        \\      emu.write(base + B5.y, shot.enY, wram)
        \\      emu.write(base + B5.x, shot.enX, wram)
        \\      emu.write(base + B5.sprite, B5.testId, wram)
        \\      -- The base attributes too, which the *draw* reads and the
        \\      -- collision does not: `drawEnemySprite_getInfo` composes the
        \\      -- flips out of +$04, +$05 and +$06 exclusive-ORed together, so a
        \\      -- slot written by hand without +$04 draws through whatever the
        \\      -- last room left there.
        \\      emu.write(base + B5.baseattr, 0, wram)
        \\      emu.write(base + B5.attr, 0, wram)
        \\      emu.write(base + B5.stun, 0, wram)
        \\      emu.write(base + B5.dirflags, 0, wram)
        \\      emu.write(base + B5.ice, 0, wram)
        \\      emu.write(base + B5.health, 0x20, wram)
        \\      emu.write(base + B5.maxhp, 0x20, wram)
        \\      emu.write(base + B5.drop, 0, wram)
        \\      emu.write(base + B5.explode, 0, wram)
        \\      emu.write(base + B5.flag, 4, wram)
        \\      emu.write(base + B5.status, 0, wram)
        \\      emu.write(B5.enTotal, 1, wram)
        \\      emu.write(B5.enActive, 1, wram)
        \\      shot.drawAt = since
        \\      return
        \\    end
        \\    -- The pass runs every other frame, so give it a few.
        \\    local used = shot.drew or rd16(RAM_OAMIDX, wram)
        \\    if shot.goneAt == nil and used <= shot.samusParts then
        \\      if since - shot.drawAt > 30 then emu.stop(170) end
        \\      return
        \\    end
        \\    -- **And then one more frame.** `!OamIdx` is WRAM and is current at
        \\    -- the end of the frame that wrote it; the shadow it counts does
        \\    -- not reach OAM until the *next* frame's NMI runs the DMA. Read on
        \\    -- the same frame, the four slots past Samus still hold what
        \\    -- `ClearUnusedOam` left in them, which is the hidden row -- and
        \\    -- that is what this phase reported until it was measured: 19
        \\    -- frames in 20 matched and the 20th was this one.
        \\    if shot.drewAt == nil then
        \\      shot.drewAt, shot.drew = since, used
        \\      return
        \\    end
        \\    -- Something was drawn after Samus. It has to be *this enemy*: at
        \\    -- least one of the objects past her parts must sit within a
        \\    -- sprite's reach of where the slot says the enemy is, converted
        \\    -- through the same two biases `PutObject` applies.
        \\    local wantY = (shot.enY - OAM_Y_OFS + BAND_TOP) & 0xFF
        \\    local wantX = (shot.enX - OAM_X_OFS + WIN_LEFT) & 0xFF
        \\    local oam = emu.memType.snesSpriteRam
        \\    -- The wide half first: the bit has to be *set* while it is needed,
        \\    -- or the step below proves nothing.
        \\    if shot.wideAt == nil then
        \\      if ninthBits(shot.samusParts, used) == 0 then emu.stop(173) end
        \\      emu.write(B5.slots + B5.x, 0x50, wram)
        \\      shot.enX = 0x50
        \\      wantX = (shot.enX - OAM_X_OFS + WIN_LEFT) & 0xFF
        \\      shot.wideAt = since
        \\      return
        \\    end
        \\    if since - shot.wideAt < 3 then return end
        \\    if shot.goneAt == nil then
        \\      -- And now every one of them has to be clear again.
        \\      if ninthBits(shot.samusParts, used) ~= 0 then emu.stop(174) end
        \\      local near = false
        \\      local i = shot.samusParts
        \\      while i < used do
        \\        local oy, ox = emu.read(i + 1, oam), emu.read(i, oam)
        \\        local dy = (oy - wantY) & 0xFF
        \\        local dx = (ox - wantX) & 0xFF
        \\        if (dy < 24 or dy > 232) and (dx < 24 or dx > 232) then near = true end
        \\        i = i + 4
        \\      end
        \\      if not near then emu.stop(171) end
        \\    end
        \\
        \\    -- **And then take it away again.** A slot the frame did not use has
        \\    -- to be parked off-screen, or it goes on showing last frame's
        \\    -- picture -- which is what `clearUnusedOamSlots` is for and what
        \\    -- the port got wrong for as long as `DrawSamus` owned the call:
        \\    -- the clear sets `!OamMax` to whatever `!OamIdx` had reached when
        \\    -- *it* ran, so anything drawn after it left slots no later frame
        \\    -- would ever hide. Nothing could see that while Samus was the only
        \\    -- thing drawn. This is the half of the phase that fails when the
        \\    -- call is put back inside her draw.
        \\    if shot.goneAt == nil then
        \\      emu.write(B5.slots + B5.status, 0xFF, wram)
        \\      emu.write(B5.enTotal, 0, wram)
        \\      emu.write(B5.enActive, 0, wram)
        \\      shot.goneAt = since
        \\      return
        \\    end
        \\    if since - shot.goneAt < 3 then return end
        \\    local j = shot.samusParts
        \\    while j < used do
        \\      if emu.read(j + 1, oam) ~= B5.hiddenY then emu.stop(172) end
        \\      j = j + 4
        \\    end
        \\    enter(16, nil)
        \\
        \\  elseif phase == 16 then
        \\    -- **And a kill that finishes.** Until Step 12e it did not: the damage
        \\    -- pass wrote `+$0E explosionFlag` and cleared nothing else, nothing
        \\    -- animated it, and **the kill path never changed the slot's status** --
        \\    -- so the corpse stayed *active*. It was still drawn, still a
        \\    -- projectile target, and `collision_projectileEnemies` went on
        \\    -- deleting every beam that touched it while the damage pass saw the
        \\    -- flag and did nothing. Measured on the shipped cart on 2026-09-09: a
        \\    -- shot fired at an enemy 28 px away died after four frames identically
        \\    -- whether the enemy was alive or a corpse. Sixteen pixels, and from
        \\    -- the player's seat it read as no beam leaving her weapon.
        \\    --
        \\    -- Three things are asserted and the third is the one that failed.
        \\    --
        \\    -- **The terrain is taken out of the question first.** Phase 13 put a
        \\    -- block sixteen pixels along this same path and broke it, and
        \\    -- `handleRespawningBlocks` has had a hundred frames to bring it back;
        \\    -- this phase needs the beam to travel further than that. So the block
        \\    -- array is emptied and the 2x2 phase 13 used is written gone. That is
        \\    -- a lever and it is the right one: what is being graded is whether a
        \\    -- *corpse* stops a beam, and leaving a block in the path would let the
        \\    -- phase pass or fail for a reason that has nothing to do with enemies.
        \\    if shot.kAt == nil then
        \\      if liveProj() ~= nil then return end
        \\      if emu.read(RAM_POSE, wram) ~= POSE_STAND then
        \\        if since > 240 then emu.stop(175) end
        \\        return
        \\      end
        \\      for i = 0, 15 do emu.write(RAM_BLOCKS + i * BLK_SIZE, 0, wram) end
        \\      if shot.blk ~= nil then
        \\        for k = 0, 3 do
        \\          local o = (k < 2) and (shot.blk + k) or (shot.blk + 30 + k)
        \\          emu.write(RAM_TILEMAP + o * 2, BLK_TILE_GONE, wram)
        \\        end
        \\      end
        \\      shot.dir = (emu.read(RAM_FACING, wram) ~= 0) and 1 or 2
        \\      hold = B5.fire
        \\      shot.kAt = since
        \\      shot.kSlot = nil
        \\      shot.kSeen = {{}}
        \\      return
        \\    end
        \\    hold = nil
        \\    if shot.kSlot == nil then
        \\      shot.kSlot = liveProj()
        \\      if shot.kSlot == nil then
        \\        if since - shot.kAt > 4 then emu.stop(175) end
        \\        return
        \\      end
        \\      -- The enemy goes where the shot is going, as in phase 14, and with
        \\      -- **one beam's worth of health**: `weapon_damage`'s first entry, so
        \\      -- 02:$4325's subtract lands on zero and the death is the cartridge's
        \\      -- arithmetic rather than a flag this script wrote.
        \\      --
        \\      -- Its *initial* health is `hpInvuln`, and that choice is what makes
        \\      -- the phase deterministic. 02:$435E refuses such an enemy a drop, so
        \\      -- the explosion flag carries no drop bits, and `.becomeDrop` then
        \\      -- reaches `.noDrop` on **either** outcome of the 50% roll -- which is
        \\      -- a substituted quantity here and must not be what a rung turns on.
        \\      local py = (emu.read(shot.kSlot + B5.tY, wram) + B5.hitBias) & 0xFF
        \\      local px = (emu.read(shot.kSlot + B5.tX, wram) + B5.hitBias) & 0xFF
        \\      if shot.dir == 1 then px = (px + 12) & 0xFF else px = (px - 12) & 0xFF end
        \\      shot.kAim = px
        \\      local scrollY = (emu.read(RAM_CAMY, wram) - GB_SCROLL_Y_BIAS) & 0xFF
        \\      local scrollX = (emu.read(RAM_CAMX, wram) - B5.scrollXBias) & 0xFF
        \\      local base = B5.slots
        \\      emu.write(base + B5.y, (py - scrollY + B5.dy) & 0xFF, wram)
        \\      emu.write(base + B5.x, (px - scrollX + B5.dx) & 0xFF, wram)
        \\      emu.write(base + B5.sprite, B5.testId, wram)
        \\      emu.write(base + B5.baseattr, 0, wram)
        \\      emu.write(base + B5.attr, 0, wram)
        \\      emu.write(base + B5.stun, 0, wram)
        \\      emu.write(base + B5.dirflags, 0, wram)
        \\      emu.write(base + B5.ice, 0, wram)
        \\      emu.write(base + B5.health, B5.dmg, wram)
        \\      emu.write(base + B5.maxhp, B4c.hpInvuln, wram)
        \\      emu.write(base + B4c.counter, 0, wram)
        \\      emu.write(base + B5.drop, 0, wram)
        \\      emu.write(base + B5.explode, 0, wram)
        \\      emu.write(base + B5.flag, 4, wram)
        \\      -- `SlotFlagOut` indexes `!SpawnFlags` with this byte and the original
        \\      -- bounds it no more than the port does, so a hand-written slot that
        \\      -- left the $FF a cleared one carries would publish past the array.
        \\      emu.write(base + B4c.number, 0x0B, wram)
        \\      emu.write(base + B5.status, 0, wram)
        \\      emu.write(B5.enTotal, 1, wram)
        \\      emu.write(B5.enActive, 1, wram)
        \\      return
        \\    end
        \\    if shot.kKill == nil then
        \\      -- The damage pass has to have killed it: the flag set, the counter
        \\      -- zeroed with it (02:$4378), and bit 5 clear, which is the ordinary
        \\      -- explosion rather than the screw attack's.
        \\      if emu.read(B5.slots + B5.explode, wram) == 0 then
        \\        if since - shot.kAt > 60 then emu.stop(175) end
        \\        return
        \\      end
        \\      if emu.read(B5.slots + B5.explode, wram) & B4c.expBig ~= 0 then emu.stop(176) end
        \\      if emu.read(B5.slots + B4c.counter, wram) ~= 0 then emu.stop(176) end
        \\      shot.kKill = since
        \\      return
        \\    end
        \\    if shot.kFree == nil then
        \\      -- The animation, while it lasts. Four frames, not three: the flag is
        \\      -- not `expShort` so 02:$56C9's `INC B` applies, and each one is an id
        \\      -- `sprExpNorm` above the counter. The pass runs every other frame, so
        \\      -- every one of them is on the screen for two frames and a per-frame
        \\      -- sample cannot miss one.
        \\      if emu.read(B5.slots + B5.status, wram) ~= 0xFF then
        \\        local spr = emu.read(B5.slots + B5.sprite, wram)
        \\        if spr >= B4c.sprExpNorm and spr <= B4c.sprExpNorm + B4c.expN then
        \\          shot.kSeen[spr] = true
        \\        end
        \\        if since - shot.kKill > 40 then emu.stop(177) end
        \\        return
        \\      end
        \\      -- **The slot freed itself**, which is the half that did not happen.
        \\      for i = 0, B4c.expN do
        \\        if not shot.kSeen[B4c.sprExpNorm + i] then emu.stop(178) end
        \\      end
        \\      if emu.read(B4c.unhandled, wram) ~= 0 then emu.stop(176) end
        \\      emu.write(B5.enTotal, 0, wram)
        \\      emu.write(B5.enActive, 0, wram)
        \\      shot.kFree = since
        \\      return
        \\    end
        \\    -- And now a beam through where it was. Before Step 12e this is the
        \\    -- shot that died in four frames on nothing.
        \\    if shot.kFire == nil then
        \\      if emu.read(RAM_POSE, wram) ~= POSE_STAND then
        \\        if since - shot.kFree > 240 then emu.stop(179) end
        \\        return
        \\      end
        \\      hold = B5.fire
        \\      shot.kFire = since
        \\      shot.kAgain = nil
        \\      return
        \\    end
        \\    hold = nil
        \\    if shot.kAgain == nil then
        \\      shot.kAgain = liveProj()
        \\      if shot.kAgain == nil then
        \\        if since - shot.kFire > 4 then emu.stop(179) end
        \\        return
        \\      end
        \\      return
        \\    end
        \\    -- How far past the corpse's old position it has reached, signed along
        \\    -- its own direction of travel. It starts twelve pixels short.
        \\    local past = (emu.read(shot.kAgain + B5.tX, wram) + B5.hitBias - shot.kAim) & 0xFF
        \\    if past > 127 then past = past - 256 end
        \\    if shot.dir ~= 1 then past = -past end
        \\    if emu.read(shot.kAgain + B5.tType, wram) == B5.none then emu.stop(179) end
        \\    if past < 8 then
        \\      if since - shot.kFire > 40 then emu.stop(179) end
        \\      return
        \\    end
        \\    enter(17, nil)
        \\
        \\  elseif phase == 17 then
        \\    -- **And the corpse that leaves something.** `enemy_animateDrop` is the
        \\    -- other arm `EnemyCommonAI` recorded as unhandled, and the collection
        \\    -- half of `enemy_getDamagedOrGiveDrop` has been ported since Step 12b
        \\    -- and could not be reached by anything: nothing could put a `+$0D` in a
        \\    -- slot. This is the phase that closes both.
        \\    --
        \\    -- The lever is the explosion flag itself, written as `expShort` -- the
        \\    -- one value of it this repository has pinned to an opcode, and exactly
        \\    -- "an ordinary death leaving small health". **The roll is retried, not
        \\    -- poked**: half of all corpses leave nothing, that half is a
        \\    -- substituted quantity on this machine, and a phase that wrote
        \\    -- `!EnFrame` to force the outcome would be grading its own lever.
        \\    if shot.dAt == nil then
        \\      if shot.dTries > 3 then emu.stop(181) end
        \\      if shot.dHold ~= nil and since < shot.dHold then return end
        \\      if liveProj() ~= nil then return end
        \\      local base = B5.slots
        \\      emu.write(base + B5.sprite, B5.testId, wram)
        \\      emu.write(base + B5.baseattr, 0, wram)
        \\      emu.write(base + B5.attr, 0, wram)
        \\      emu.write(base + B5.stun, 0, wram)
        \\      emu.write(base + B5.dirflags, 0, wram)
        \\      emu.write(base + B5.ice, 0, wram)
        \\      emu.write(base + B5.health, 0, wram)
        \\      emu.write(base + B5.maxhp, 0x20, wram)
        \\      emu.write(base + B4c.counter, 0, wram)
        \\      emu.write(base + B5.drop, 0, wram)
        \\      emu.write(base + B5.explode, B4c.expShort, wram)
        \\      emu.write(base + B5.flag, 4, wram)
        \\      emu.write(base + B4c.number, 0x0B, wram)
        \\      emu.write(base + B5.status, 0, wram)
        \\      emu.write(B5.enTotal, 1, wram)
        \\      emu.write(B5.enActive, 1, wram)
        \\      shot.dAt, shot.dTries = since, shot.dTries + 1
        \\      return
        \\    end
        \\    if shot.dGot == nil then
        \\      if emu.read(B5.slots + B5.status, wram) == 0xFF then
        \\        -- The roll came up the other way: this corpse left nothing, which
        \\        -- is `.noDrop` and is correct. Make another one.
        \\        --
        \\        -- **Not at the same spacing every time.** Each try takes the same
        \\        -- number of passes, N, so evenly spaced tries all roll on the
        \\        -- parity of the first plus multiples of N -- one parity forever
        \\        -- when N is even, and which N a cart gets moved with the boot's
        \\        -- length (`docs/bug_tracker.md`, 2026-09-15). The third try waits
        \\        -- two frames more, which is one acting pass: it rolls on the
        \\        -- first's parity plus 2N+1, the other parity whatever N is.
        \\        emu.write(B5.enTotal, 0, wram)
        \\        emu.write(B5.enActive, 0, wram)
        \\        if shot.dTries == 2 then shot.dHold = since + 2 end
        \\        shot.dAt = nil
        \\        return
        \\      end
        \\      if emu.read(B5.slots + B5.drop, wram) == 0 then
        \\        if since - shot.dAt > 40 then emu.stop(180) end
        \\        return
        \\      end
        \\      -- $570F's `LD BC,$01E0`, both halves, and the four bytes the corpse
        \\      -- no longer needs.
        \\      if emu.read(B5.slots + B5.drop, wram) ~= B4c.dropSmall then emu.stop(180) end
        \\      if emu.read(B5.slots + B5.sprite, wram) ~= B4c.sprDropSmall then emu.stop(180) end
        \\      if emu.read(B5.slots + B5.explode, wram) ~= 0 then emu.stop(180) end
        \\      if emu.read(B5.slots + B4c.counter, wram) ~= 0 then emu.stop(180) end
        \\      shot.dGot = since
        \\      return
        \\    end
        \\    -- The blink. One pass in four for the drop's first $80 counts, and a
        \\    -- pass is every other frame, so both ids are on the screen inside forty.
        \\    if shot.dTake == nil then
        \\      -- **And the property the roll rests on, while there is a loop to
        \\      -- sample it in.** `!EnSame` reads 1 at the end of exactly the frames
        \\      -- the pass acted on, so this asks whether the counter the roll
        \\      -- divides takes both values across consecutive acting passes. It is
        \\      -- the whole reason the substitution reads `!EnFrame` and not
        \\      -- `!FrameCount`: measured on this cart on 2026-09-12, `!FrameCount`'s
        \\      -- low bit is the *same* on every acting pass for 1000 frames of a
        \\      -- room, because the pass acts on one frame parity and `!EnSame`
        \\      -- toggles once a frame. A roll reading it would give every corpse in
        \\      -- the room the same answer.
        \\      if emu.read(B4c.enSame, wram) == 1 then
        \\        if emu.read(B4c.enFrame, wram) & 1 == 0 then
        \\          shot.pLo = true
        \\        else
        \\          shot.pHi = true
        \\        end
        \\      end
        \\      local spr = emu.read(B5.slots + B5.sprite, wram)
        \\      if spr == B4c.sprDropSmall then shot.dLo = true end
        \\      if spr == (B4c.sprDropSmall ~ B4c.dropBlink) then shot.dHi = true end
        \\      if not (shot.dLo and shot.dHi) then
        \\        if since - shot.dGot > 60 then emu.stop(182) end
        \\        return
        \\      end
        \\      if not (shot.pLo and shot.pHi) then emu.stop(184) end
        \\      -- And then Samus collects it, which is the arm Step 12b ported blind.
        \\      -- Her health is put somewhere a refill can move: a BCD $99 would be
        \\      -- clamped back to $99 by 02:$4284 and the phase would prove nothing.
        \\      emu.write(B4c.healthLo, 0x10, wram)
        \\      emu.write(B4c.healthHi, 0, wram)
        \\      emu.write(B5.collWeapon, 0x20, wram)
        \\      emu.write(B5.collEnemy, 0, wram)
        \\      emu.write(B5.collEnemy + 1, 0, wram)
        \\      shot.dTake = since
        \\      return
        \\    end
        \\    if emu.read(B5.slots + B5.status, wram) ~= 0xFF then
        \\      if since - shot.dTake > 40 then emu.stop(183) end
        \\      return
        \\    end
        \\    -- 02:$426F's `$05`, added in BCD, and the slot gone with it.
        \\    if emu.read(B4c.healthLo, wram) ~= 0x15 then emu.stop(183) end
        \\    if emu.read(B4c.healthHi, wram) ~= 0 then emu.stop(183) end
        \\    if emu.read(B4c.unhandled, wram) ~= 0 then emu.stop(176) end
        \\    -- Missiles next, while she is still standing from the shots above;
        \\    -- the bombs leave her thrown and in the ball, and a stand forced
        \\    -- onto that falls. So phase 19 runs between 17 and 18.
        \\    enter(19, nil)
        \\
        \\  elseif phase == 18 then
        \\    -- **B5's bombs.** Until Step 12c a ball pose's fire button reached
        \\    -- `samus_layBomb` and recorded that it had, and nothing on this cart
        \\    -- could lay one. The lever is the fire button again, and every
        \\    -- number the phase checks against is the cartridge's.
        \\    --
        \\    -- Four stages. The ball at rest; one press *without* the Bomb, which
        \\    -- must lay nothing; one press with it, held for 24 frames, which must
        \\    -- lay exactly one; and the fuse, the explosion and what it leaves.
        \\    if bm.step == nil then
        \\      if liveProj() ~= nil then return end
        \\      if since > 600 then emu.stop(186) end
        \\      -- The ball, forced only when she is not already in a ball pose --
        \\      -- phase 10 measured what forcing it every frame does.
        \\      if pose ~= POSE_MORPH and pose ~= POSE_BALLJUMP and pose ~= POSE_BALLFALL then
        \\        emu.write(RAM_POSE, POSE_MORPH, wram)
        \\      end
        \\      emu.write(RAM_DOWNSPEED, 0, wram)
        \\      if pose ~= POSE_MORPH or samy ~= bm.y then
        \\        bm.y, bm.still = samy, since
        \\        return
        \\      end
        \\      if since - bm.still < 8 then return end
        \\      bm.items = emu.read(RAM_ITEMS, wram)
        \\      emu.write(RAM_ITEMS, bm.items & (0xFF ~ BM.itemMask), wram)
        \\      for i = 0, 15 do emu.write(RAM_BLOCKS + i * BLK_SIZE, 0, wram) end
        \\      hold = B5.fire
        \\      bm.step, bm.at = 1, since
        \\      return
        \\    end
        \\    if bm.step == 1 then
        \\      -- 01:$53DC's `BIT 0,A`: no Bomb, no bomb.
        \\      hold = nil
        \\      if bm.live() ~= nil then emu.stop(185) end
        \\      if since - bm.at < 6 then return end
        \\      emu.write(RAM_ITEMS, bm.items, wram)
        \\      -- Two blocks, where the explosion will ask: a bomb-only block at its
        \\      -- left tile and a respawning block at its right. Both positions are
        \\      -- the cartridge's -- where 01:$5400 lays the bomb and how far
        \\      -- 01:$5528 looks from it -- so a probe at the wrong distance misses
        \\      -- a block rather than hitting a neighbour.
        \\      bm.by = ((samy & 0xFF) + BM.layY) & 0xFF
        \\      bm.bx = ((samx & 0xFF) + BM.layX) & 0xFF
        \\      bm.bombBlk = bm.slotAt(bm.by, (bm.bx - BM.probe) & 0xFF)
        \\      bm.respY, bm.respX = bm.by, (bm.bx + BM.probe) & 0xFF
        \\      local rs = bm.slotAt(bm.respY, bm.respX)
        \\      for k = 0, 3 do
        \\        local o = (k < 2) and (bm.bombBlk + k) or (bm.bombBlk + 30 + k)
        \\        emu.write(RAM_TILEMAP + o * 2, BM.tile, wram)
        \\        local r = (k < 2) and (rs + k) or (rs + 30 + k)
        \\        emu.write(RAM_TILEMAP + r * 2, BLK_TILE_SOLID + k, wram)
        \\      end
        \\      hold = B5.fire
        \\      bm.step, bm.at = 2, since
        \\      return
        \\    end
        \\    if bm.step == 2 then
        \\      -- Held for 24 frames: the rising edge is the gate, so one press
        \\      -- is one bomb however long it lasts. Longer than `samusShoot`'s
        \\      -- $10-frame cooldown on purpose -- inside it a held button never
        \\      -- reaches the bomb arm at all, and 01:$53E1 would go ungraded.
        \\      hold = (since - bm.at < 24) and B5.fire or nil
        \\      local slot, n = bm.live()
        \\      if slot == nil then
        \\        if since - bm.at > 4 then emu.stop(186) end
        \\        return
        \\      end
        \\      if n > 1 then emu.stop(188) end
        \\      if bm.slot == nil then
        \\        bm.slot, bm.seen, bm.t0 = slot, since, emu.read(slot + 1, wram)
        \\        if emu.read(slot, wram) ~= BM.live then emu.stop(187) end
        \\        if emu.read(slot + 2, wram) ~= bm.by then emu.stop(187) end
        \\        if emu.read(slot + 3, wram) ~= bm.bx then emu.stop(187) end
        \\        if bm.t0 > BM.fuse or bm.t0 + 4 < BM.fuse then emu.stop(191) end
        \\        if emu.read(B5.unhandled, wram) ~= 0xFF then emu.stop(166) end
        \\        -- The enemy, diagonally below and behind the explosion by eight
        \\        -- pixels more than its own half-extents on each axis. So the box
        \\        -- `collision_projectileOneEnemy` would test misses on both axes
        \\        -- and the hit needs 00:$3120's padding on both -- the vertical
        \\        -- half of which is the engine's own arithmetic after
        \\        -- `LoadEnemyBox` and graded by nothing else.
        \\        local scrollY = (emu.read(RAM_CAMY, wram) - GB_SCROLL_Y_BIAS) & 0xFF
        \\        local scrollX = (emu.read(RAM_CAMX, wram) - B5.scrollXBias) & 0xFF
        \\        local sy, sx = (bm.by - scrollY) & 0xFF, (bm.bx - scrollX) & 0xFF
        \\        local base = B5.slots
        \\        emu.write(base + B5.y, (sy + BM.enH + 8 + BM.enDy) & 0xFF, wram)
        \\        emu.write(base + B5.x, (sx - BM.enW - 8 + BM.enDx) & 0xFF, wram)
        \\        emu.write(base + B5.sprite, BM.enId, wram)
        \\        emu.write(base + B5.baseattr, 0, wram)
        \\        emu.write(base + B5.attr, 0, wram)
        \\        emu.write(base + B5.stun, 0, wram)
        \\        emu.write(base + B5.dirflags, 0, wram)
        \\        emu.write(base + B5.ice, 0, wram)
        \\        emu.write(base + B5.health, 0x20, wram)
        \\        emu.write(base + B5.maxhp, 0x20, wram)
        \\        emu.write(base + B5.drop, 0, wram)
        \\        emu.write(base + B5.explode, 0, wram)
        \\        emu.write(base + B5.flag, 4, wram)
        \\        emu.write(base + B5.status, 0, wram)
        \\        emu.write(B5.enTotal, 1, wram)
        \\        emu.write(B5.enActive, 1, wram)
        \\        bm.hp = 0x20
        \\        return
        \\      end
        \\      if since - bm.at < 24 then return end
        \\      bm.step = 3
        \\      return
        \\    end
        \\    if bm.step == 3 then
        \\      local slot = bm.slot
        \\      local t = emu.read(slot, wram)
        \\      local scrollY = (emu.read(RAM_CAMY, wram) - GB_SCROLL_Y_BIAS) & 0xFF
        \\      local scrollX = (emu.read(RAM_CAMX, wram) - B5.scrollXBias) & 0xFF
        \\      local sy, sx = (bm.by - scrollY) & 0xFF, (bm.bx - scrollX) & 0xFF
        \\      local timer = emu.read(slot + 1, wram)
        \\      if t == BM.live then
        \\        -- **Drawn, and drawn first.** OAM is a frame behind the shadow, so
        \\        -- object 0 is last frame's bomb: `drawBombs` runs inside the Samus
        \\        -- block, before `drawSamus`, and `DrawSamus` used to zero the
        \\        -- index -- which would erase the bomb every frame it was drawn.
        \\        if bm.prev ~= nil then
        \\          local id = BM.sprBomb + (((bm.prev.timer & 8) ~= 0) and 1 or 0)
        \\          local oam = emu.memType.snesSpriteRam
        \\          local wx = ((bm.prev.sx + SPR_DX[id]) & 0xFF) - OAM_X_OFS + WIN_LEFT
        \\          local wy = ((bm.prev.sy + SPR_DY[id]) & 0xFF) - OAM_Y_OFS + BAND_TOP
        \\          if emu.read(0, oam) ~= (wx & 0xFF) then emu.stop(189) end
        \\          if (emu.read(512, oam) & 1) ~= (wx >> 8) then emu.stop(189) end
        \\          if emu.read(1, oam) ~= (wy & 0xFF) then emu.stop(189) end
        \\          bm.drawn = true
        \\        end
        \\        bm.prev = {{ timer = timer, sx = sx, sy = sy }}
        \\        if since - bm.seen > BM.fuse + 4 then emu.stop(191) end
        \\        return
        \\      end
        \\      if not bm.drawn then emu.stop(189) end
        \\      -- The fuse ran out on exactly the frame 01:$53FB's count says, and
        \\      -- the explosion has 01:$54C5's.
        \\      if t ~= BM.blast then emu.stop(191) end
        \\      if since - bm.seen ~= bm.t0 then emu.stop(191) end
        \\      if timer ~= BM.blastN then emu.stop(191) end
        \\      -- **And on that same frame, the explosion's whole effect.** The
        \\      -- bomb-only block is gone, which is `!BLOCK_BOMB`'s first reader;
        \\      -- the respawning block's position is in the block array, which is
        \\      -- the right probe at the cartridge's distance; and Samus is in the
        \\      -- pose `samus_bombPoseTable` gives the ball.
        \\      if not blkIsGone(bm.bombBlk) then emu.stop(192) end
        \\      local found = false
        \\      for i = 0, 15 do
        \\        local o = RAM_BLOCKS + i * BLK_SIZE
        \\        if emu.read(o, wram) ~= 0 and emu.read(o + 1, wram) == bm.respY
        \\          and emu.read(o + 2, wram) == bm.respX then found = true end
        \\      end
        \\      if not found then emu.stop(193) end
        \\      if emu.read(RAM_POSE, wram) ~= BM.hitPose then emu.stop(194) end
        \\      bm.step, bm.blastAt = 4, since
        \\      return
        \\    end
        \\    -- The enemy the explosion reached, and the slot freeing itself.
        \\    local ago = since - bm.blastAt
        \\    local hp = emu.read(B5.slots + B5.health, wram)
        \\    if hp ~= bm.hp and bm.hit == nil then
        \\      if hp ~= bm.hp - BM.dmg then emu.stop(195) end
        \\      bm.hit = true
        \\    end
        \\    if ago < BM.blastN then
        \\      if emu.read(bm.slot, wram) ~= BM.blast then emu.stop(196) end
        \\      return
        \\    end
        \\    if ago == BM.blastN and emu.read(bm.slot, wram) ~= BM.none then emu.stop(196) end
        \\    if bm.hit == nil then
        \\      if ago > 60 then emu.stop(195) end
        \\      return
        \\    end
        \\    if emu.read(B5.unhandled, wram) ~= 0xFF then emu.stop(166) end
        \\    -- The pickup's rise has to have been seen by now, in phase 9.
        \\    if hud.raised == nil then emu.stop(207) end
        \\    enter(20, nil)
        \\
        \\  elseif phase == 20 then
        \\    -- **The HUD, Step 13b.** `adjustHudValues` rolls the displayed
        \\    -- health one unit a frame toward the real one and asks for a tick of
        \\    -- sound on every fourth; the icon beside the count changes sprite
        \\    -- with `frameCounter` bit 4, which `checkSprite` holds every frame
        \\    -- and this phase requires both sprites of. The digits are the HUD
        \\    -- oracle's, tick for tick against the Game Boy.
        \\    if hud.step == nil then
        \\      hold = nil
        \\      if liveProj() ~= nil or bm.live() ~= nil or since < 4 then return end
        \\      emu.write(HUD.dispH, 0x50, wram)
        \\      emu.write(HUD.dispH + 1, 0x00, wram)
        \\      emu.write(HUD.health, 0x47, wram)
        \\      emu.write(HUD.health + 1, 0x00, wram)
        \\      emu.write(HUD.sfx1, 0, wram)
        \\      hud.step, hud.want, hud.at, hud.ticks = 1, 0x50, since, 0
        \\      return
        \\    end
        \\    if hud.step == 1 then
        \\      local d = rd16(HUD.dispH, wram)
        \\      local rolled = hud.want ~= 0x47
        \\      -- One unit in BCD: $50 is followed by $49.
        \\      if rolled then hud.want = (hud.want & 0x0F) == 0 and hud.want - 7 or hud.want - 1 end
        \\      if d ~= hud.want then emu.stop(208) end
        \\      local tick = emu.read(HUD.sfx1, wram) == HUD.sfxTick
        \\      local due = rolled and (hud.logicFc() & HUD.every) == 0
        \\      if tick ~= due then emu.stop(209) end
        \\      if due then hud.ticks = hud.ticks + 1 end
        \\      emu.write(HUD.sfx1, 0, wram)
        \\      if since - hud.at < 40 then return end
        \\      -- Three steps and then nothing, whatever the counter did.
        \\      if d ~= 0x47 then emu.stop(208) end
        \\      hud.step = 2
        \\      return
        \\    end
        \\    if since - hud.at < 80 then return end
        \\    if not (hud.seen[HUD.spr] and hud.seen[HUD.spr + 1]) then emu.stop(206) end
        \\    enter(21, nil)
        \\
        \\  elseif phase == 21 then
        \\    -- **A Metroid appearing, Step 13c.** The enemy oracle grades the
        \\    -- Alphas pass for pass against the Game Boy, but it stands Samus
        \\    -- still, so what `cutsceneActive` does to *her* is invisible to it,
        \\    -- and so is the coin, which it hands across. Two halves.
        \\    --
        \\    -- The freeze: with the flag raised and a direction held she may not move, a
        \\    -- turnaround bit is cleared (00:$0514), the pad does not reach her
        \\    -- sprite (01:$4C05), and Select still toggles -- resuming past the
        \\    -- Samus block, not into it. Lowered, the pad moves her, which is what
        \\    -- says the lever did anything.
        \\    if al.step == nil then
        \\      hold = nil
        \\      if liveProj() ~= nil or bm.live() ~= nil then return end
        \\      if since > 600 then emu.stop(210) end
        \\      -- Phase 18 leaves her a ball. Up, pressed rather than held, stands
        \\      -- her up out of it.
        \\      if pose ~= POSE_STAND then
        \\        if since % 8 < 4 then hold = "up" end
        \\        al.x = nil
        \\        return
        \\      end
        \\      if samx ~= al.x then
        \\        al.x, al.still = samx, since
        \\        return
        \\      end
        \\      if since - al.still < 8 then return end
        \\      al.id = sprId
        \\      emu.write(AL.cutscene, 1, wram)
        \\      emu.write(RAM_POSE, pose | 0x80, wram)
        \\      -- Away from the way she faces: a pad toward her back is the one
        \\      -- whose bits change the sprite tables' answer.
        \\      al.away = emu.read(RAM_FACING, wram) == 0 and "right" or "left"
        \\      hold = al.away
        \\      al.step, al.at = 1, since
        \\      return
        \\    end
        \\    if al.step == 1 then
        \\      if samx ~= al.x then emu.stop(210) end
        \\      if pose & 0x80 ~= 0 then emu.stop(211) end
        \\      if sprId ~= al.id then emu.stop(212) end
        \\      if since - al.at < 30 then return end
        \\      hold = "select"
        \\      al.step, al.at = 2, since
        \\      return
        \\    end
        \\    if al.step == 2 then
        \\      hold = nil
        \\      if samx ~= al.x then emu.stop(210) end
        \\      local h = emu.read(AL.hold, wram)
        \\      if h ~= 0 then
        \\        if h ~= AL.holdCutscene then emu.stop(213) end
        \\        if emu.read(AL.weapon, wram) ~= AL.missile then emu.stop(213) end
        \\        al.held = since
        \\        return
        \\      end
        \\      if al.held == nil then
        \\        if since - al.at > 6 then emu.stop(213) end
        \\        return
        \\      end
        \\      -- The resumed frame must not have run the Samus block: nothing fired.
        \\      if liveProj() ~= nil then emu.stop(213) end
        \\      hold = "select"
        \\      al.step, al.at, al.held = 3, since, nil
        \\      return
        \\    end
        \\    if al.step == 3 then
        \\      hold = nil
        \\      if emu.read(AL.hold, wram) ~= 0 then return end
        \\      if since - al.at < 4 then return end
        \\      if emu.read(AL.weapon, wram) ~= emu.read(AL.beam, wram) then emu.stop(213) end
        \\      if samx ~= al.x then emu.stop(210) end
        \\      emu.write(AL.cutscene, 0, wram)
        \\      hold = al.away
        \\      al.step, al.at = 4, since
        \\      return
        \\    end
        \\    if al.step == 4 then
        \\      if samx == al.x then
        \\        if since - al.at > 20 then emu.stop(210) end
        \\        return
        \\      end
        \\      hold = nil
        \\      al.step, al.trials, al.coins = 5, 0, {{}}
        \\      return
        \\    end
        \\    -- The coin: a fighting Alpha in slot 0, far from Samus, shot with a
        \\    -- missile from the left six times, each shot written a pass later
        \\    -- than the last relative to the stun ending, so the hurts land on
        \\    -- passes of both parities. The coin is read back out of the flag
        \\    -- the hurt set on the vertical axis, and must be the low bit of
        \\    -- `!EnFrame` as the pass that set it left it -- and come up both ways.
        \\    local base = B5.slots
        \\    if al.step == 5 then
        \\      hold = nil
        \\      emu.write(base + B5.status, 0, wram)
        \\      emu.write(base + B5.y, 0x30, wram)
        \\      emu.write(base + B5.x, 0x30, wram)
        \\      emu.write(base + B5.sprite, AL.sprAlpha, wram)
        \\      emu.write(base + B5.baseattr, 0, wram)
        \\      emu.write(base + B5.attr, 0, wram)
        \\      emu.write(base + B5.stun, 0, wram)
        \\      emu.write(base + B5.dirflags, 0xFF, wram)
        \\      emu.write(base + B5.ice, 0, wram)
        \\      emu.write(base + B5.health, 0x40, wram)
        \\      emu.write(base + B4c.counter, 0, wram)
        \\      emu.write(base + B5.drop, 0, wram)
        \\      emu.write(base + B5.explode, 0, wram)
        \\      emu.write(base + B5.flag, 4, wram)
        \\      emu.write(base + 0x1E, AL.ai & 0xFF, wram)
        \\      emu.write(base + 0x1F, AL.ai >> 8, wram)
        \\      emu.write(B5.enTotal, 1, wram)
        \\      emu.write(B5.enActive, 1, wram)
        \\      emu.write(AL.fight, 1, wram)
        \\      emu.write(AL.state, AL.stateFight, wram)
        \\      emu.write(AL.stun, 0, wram)
        \\      al.step, al.at = 6, since
        \\      return
        \\    end
        \\    if al.step == 6 then
        \\      -- Wait out the stun, then the trial's extra frames, then shoot. It
        \\      -- is held where it was put and inside its lunge's pause, because a
        \\      -- lunge reaches Samus in a few seconds and hurts her.
        \\      emu.write(base + B5.y, 0x30, wram)
        \\      emu.write(base + B5.x, 0x30, wram)
        \\      emu.write(base + B4c.counter, 0x0E, wram)
        \\      if emu.read(AL.stun, wram) ~= 0 then al.at = since return end
        \\      if since - al.at < 4 + al.trials then return end
        \\      emu.write(B5.collWeapon, AL.missile, wram)
        \\      emu.write(B5.collEnemy, 0, wram)
        \\      emu.write(B5.collEnemy + 1, 0, wram)
        \\      emu.write(AL.collDir, 0x01, wram)
        \\      emu.write(base + B5.health, 0x40, wram)
        \\      al.step, al.at = 7, since
        \\      return
        \\    end
        \\    if al.step == 7 then
        \\      if emu.read(AL.stun, wram) ~= AL.stunN then
        \\        if since - al.at > 8 then emu.stop(214) end
        \\        return
        \\      end
        \\      local df = emu.read(base + B5.dirflags, wram)
        \\      local coin = (df & 0x02) ~= 0 and 1 or 0
        \\      if ((df & 0x0A) == 0x0A) or ((df & 0x0A) == 0) then emu.stop(214) end
        \\      if coin ~= (emu.read(B4c.enFrame, wram) & 1) then emu.stop(214) end
        \\      al.coins[coin] = true
        \\      al.trials = al.trials + 1
        \\      if al.trials < 6 then
        \\        al.step, al.at = 6, since
        \\        return
        \\      end
        \\      if not (al.coins[0] and al.coins[1]) then emu.stop(215) end
        \\      emu.write(base + B5.status, 0xFF, wram)
        \\      emu.write(B5.enTotal, 0, wram)
        \\      emu.write(B5.enActive, 0, wram)
        \\      enter(22, nil)
        \\    end
        \\
        \\  elseif phase == 22 then
        \\    -- **The kill, Step 13d.** The enemy oracle grades both kills pass for
        \\    -- pass against the Game Boy, collapsed; what it cannot see is which
        \\    -- frames the timer steps on, the two song requests it records, the
        \\    -- earthquake recorder, the band's digits, and a transition that ends
        \\    -- a fight -- no case crosses a door. Two kills: the first from a real
        \\    -- count of $10, so the BCD borrow is exercised and the restore asks
        \\    -- for the room's song; the second from $01, so the restore asks for
        \\    -- nothing because none are left. Then the transition, with and
        \\    -- without a fight.
        \\    local base, KL, kl = B5.slots, AL.KL, al.kl
        \\    local function placeAlpha()
        \\      emu.write(base + B5.status, 0, wram)
        \\      emu.write(base + B5.y, 0x30, wram)
        \\      emu.write(base + B5.x, 0x30, wram)
        \\      emu.write(base + B5.sprite, AL.sprAlpha, wram)
        \\      emu.write(base + B5.baseattr, 0, wram)
        \\      emu.write(base + B5.attr, 0, wram)
        \\      emu.write(base + B5.stun, 0, wram)
        \\      emu.write(base + B5.dirflags, 0xFF, wram)
        \\      emu.write(base + B5.ice, 0, wram)
        \\      emu.write(base + B5.health, 1, wram)
        \\      emu.write(base + B4c.counter, 0x0E, wram)
        \\      emu.write(base + B5.drop, 0, wram)
        \\      emu.write(base + B5.explode, 0, wram)
        \\      emu.write(base + B5.flag, 4, wram)
        \\      emu.write(base + 0x1E, AL.ai & 0xFF, wram)
        \\      emu.write(base + 0x1F, AL.ai >> 8, wram)
        \\      emu.write(B5.enTotal, 1, wram)
        \\      emu.write(B5.enActive, 1, wram)
        \\      emu.write(AL.fight, 1, wram)
        \\      emu.write(AL.state, AL.stateFight, wram)
        \\      emu.write(AL.stun, 0, wram)
        \\    end
        \\    if kl.step == nil then
        \\      hold = nil
        \\      kl.trial = (kl.trial or 0) + 1
        \\      -- A song id no door in the region plays, so the restore's request is
        \\      -- its own and not a coincidence.
        \\      emu.write(KL.song, 0x03, wram)
        \\      emu.write(KL.real, kl.trial == 1 and 0x10 or 0x01, wram)
        \\      emu.write(KL.disp, kl.trial == 1 and 0x40 or 0x01, wram)
        \\      emu.write(KL.quake, 0, wram)
        \\      emu.write(KL.metSong, 0xFF, wram)
        \\      emu.write(KL.postDeath, 0, wram)
        \\      placeAlpha()
        \\      emu.write(B5.collWeapon, AL.missile, wram)
        \\      emu.write(B5.collEnemy, 0, wram)
        \\      emu.write(B5.collEnemy + 1, 0, wram)
        \\      emu.write(AL.collDir, 0x01, wram)
        \\      kl.step, kl.at = 1, since
        \\      return
        \\    end
        \\    if kl.step == 1 then
        \\      -- Held in place until the pass lands, as phase 21 holds it.
        \\      if emu.read(AL.state, wram) ~= KL.dying then
        \\        emu.write(base + B5.y, 0x30, wram)
        \\        emu.write(base + B5.x, 0x30, wram)
        \\        if since - kl.at > 8 then emu.stop(216) end
        \\        return
        \\      end
        \\      if emu.read(AL.fight, wram) ~= KL.died then emu.stop(216) end
        \\      if emu.read(base + B5.flag, wram) ~= 2 then emu.stop(216) end
        \\      if emu.read(KL.metSong, wram) ~= KL.songKilled then emu.stop(216) end
        \\      local spr = emu.read(base + B5.sprite, wram)
        \\      if spr ~= KL.sprExp and spr ~= KL.sprExp + 1 then emu.stop(216) end
        \\      local wantReal = kl.trial == 1 and 0x09 or 0x00
        \\      if emu.read(KL.real, wram) ~= wantReal then emu.stop(217) end
        \\      if emu.read(KL.disp, wram) ~= (kl.trial == 1 and 0x39 or 0x00) then emu.stop(217) end
        \\      if emu.read(KL.shuffle, wram) == 0 then emu.stop(217) end
        \\      -- `earthquakeCheck`: $09 is a threshold and $00 is not. Cleared at once,
        \\      -- so the quake it arms does not start under the checks that follow.
        \\      if emu.read(KL.quake, wram) ~= (kl.trial == 1 and 3 or 0) then emu.stop(217) end
        \\      emu.write(KL.quake, 0, wram)
        \\      kl.step, kl.at, kl.frames, kl.state = 2, since, {{}}, 0
        \\      kl.steps, kl.last, kl.prevPd = 0, nil, emu.read(KL.postDeath, wram)
        \\      return
        \\    end
        \\    -- From here every frame: the timer's steps, by the frame counter.
        \\    local pd = emu.read(KL.postDeath, wram)
        \\    local fc = emu.read(KL.frame, wram)
        \\    if kl.step == 2 or kl.step == 3 then
        \\      if pd ~= kl.prevPd and pd ~= 0 then
        \\        if pd ~= kl.prevPd + 1 then emu.stop(219) end
        \\        -- 02:$4041: the step is taken when the counter the handler reads
        \\        -- is even. This script reads it at the end of the frame, which is
        \\        -- before the next NMI adds one, so it is the counter the handler
        \\        -- read -- and the recording agrees: its steps land on frames whose
        \\        -- $FF97 is even at the end of the frame (16 890, 73 391).
        \\        if fc & 1 ~= 0 then emu.stop(219) end
        \\        if kl.last ~= nil and since - kl.last ~= 2 then emu.stop(219) end
        \\        kl.last, kl.steps = since, kl.steps + 1
        \\      end
        \\    end
        \\    if kl.step == 2 then
        \\      -- The explosion: Samus frozen, the six frames a pass apart, four
        \\      -- times, and the slot gone with Samus thawed.
        \\      local st = emu.read(base + B5.status, wram)
        \\      if st ~= 0xFF then
        \\        if emu.read(KL.cutscene, wram) ~= 1 and since - kl.at > 2 then emu.stop(218) end
        \\        kl.frames[emu.read(base + B5.sprite, wram)] = true
        \\        kl.state = math.max(kl.state, emu.read(base + 0x0A, wram))
        \\        if since - kl.at > 120 then emu.stop(218) end
        \\      else
        \\        if kl.state ~= 3 then emu.stop(218) end
        \\        for i = 0, KL.expN - 1 do
        \\          if not kl.frames[KL.sprExp + i] then emu.stop(218) end
        \\        end
        \\        if emu.read(KL.cutscene, wram) ~= 0 then emu.stop(218) end
        \\        if emu.read(AL.state, wram) ~= 0 then emu.stop(218) end
        \\        if emu.read(B5.enTotal, wram) ~= 0 then emu.stop(218) end
        \\        kl.step = 3
        \\      end
        \\      kl.prevPd = pd
        \\      return
        \\    end
        \\    if kl.step == 3 then
        \\      if emu.read(AL.fight, wram) == KL.died then
        \\        if pd > KL.postDeathN then emu.stop(219) end
        \\        if since - kl.at > 2 * KL.postDeathN + 8 then emu.stop(219) end
        \\        kl.prevPd = pd
        \\        return
        \\      end
        \\      -- The restore ran: $90 steps, then the song and the clears.
        \\      if kl.steps ~= KL.postDeathN then emu.stop(219) end
        \\      if pd ~= 0 or emu.read(AL.fight, wram) ~= 0 or emu.read(AL.state, wram) ~= 0 then emu.stop(221) end
        \\      local want = kl.trial == 1 and (0x03 + KL.restore) or KL.songKilled
        \\      if emu.read(KL.metSong, wram) ~= want then emu.stop(220) end
        \\      kl.step, kl.at = 4, since
        \\      return
        \\    end
        \\    if kl.step == 4 then
        \\      -- The band, once the shuffle has run out: the count's two digits.
        \\      if emu.read(KL.shuffle, wram) ~= 0 then
        \\        if since - kl.at > 0xC0 + 8 then emu.stop(221) end
        \\        return
        \\      end
        \\      if since - kl.at < 4 then return end
        \\      local d = emu.read(KL.disp, wram)
        \\      local tens = emu.read(HUD.map + KL.atCount * 2, vram)
        \\      local ones = emu.read(HUD.map + (KL.atCount + 1) * 2, vram)
        \\      if tens ~= KL.digit + (d >> 4) or ones ~= KL.digit + (d & 15) then emu.stop(221) end
        \\      if kl.trial == 1 then
        \\        kl.step = nil
        \\        return
        \\      end
        \\      kl.step = 5
        \\      return
        \\    end
        \\    if kl.step == 5 then
        \\      -- A door starting mid-fight: the room's song comes back and the
        \\      -- timer is cleared, where the room load alone would do neither.
        \\      -- The second kill left no Metroids, and with none the restore asks
        \\      -- for nothing, so one is put back first.
        \\      emu.write(KL.real, 0x45, wram)
        \\      emu.write(KL.song, 0x05, wram)
        \\      emu.write(KL.metSong, 0xFF, wram)
        \\      emu.write(AL.fight, 1, wram)
        \\      emu.write(KL.postDeath, 0x21, wram)
        \\      emu.write(KL.reload, 2, wram)
        \\      kl.step, kl.at = 6, since
        \\      return
        \\    end
        \\    if kl.step == 6 then
        \\      if since - kl.at < 2 then return end
        \\      if emu.read(KL.metSong, wram) ~= 0x05 + KL.restore then emu.stop(222) end
        \\      if emu.read(KL.postDeath, wram) ~= 0 then emu.stop(222) end
        \\      -- And no fight: a door alone asks for nothing and leaves the timer.
        \\      emu.write(KL.metSong, 0xFF, wram)
        \\      emu.write(AL.fight, 0, wram)
        \\      emu.write(KL.postDeath, 0x21, wram)
        \\      emu.write(KL.reload, 2, wram)
        \\      kl.step, kl.at = 7, since
        \\      return
        \\    end
        \\    if kl.step == 7 then
        \\      if since - kl.at < 2 then return end
        \\      if emu.read(KL.metSong, wram) ~= 0xFF then emu.stop(222) end
        \\      if emu.read(KL.postDeath, wram) ~= 0x21 then emu.stop(222) end
        \\      emu.write(KL.postDeath, 0, wram)
        \\      enter(23, nil)
        \\    end
        \\
        \\  elseif phase == 23 then
        \\    -- **The Metroid chain, Step 14.** First the gates: door $04A driven
        \\    -- rightward at a count of $47 and then $46, and door $0D9 at $47, $46
        \\    -- and $42. 00:$254A takes the branch when the count is at or below the
        \\    -- operand, so one kill changes the table the room is drawn and
        \\    -- collided through -- and a cart that only recorded the opcode kept
        \\    -- the no-kill table, which is the acid room a playtest walked into.
        \\    local MC, mc = AL.MC, al.mc
        \\    if mc.gate == nil then mc.gate = 0 end
        \\    -- The gates land her in the lava rooms' acid, which has hurt since
        \\    -- Step 22 gave a new game its damage values, and the quake's 510
        \\    -- frames are long enough to kill her there. Neither grades health,
        \\    -- so it is held until the acid step, which does.
        \\    if mc.ac == nil then
        \\      emu.write(AL.SV.healthLo, 0x99, wram)
        \\      emu.write(AL.SV.healthLo + 1, 0x01, wram)
        \\    end
        \\    if mc.gate < #MC.gate then
        \\      local g = MC.gate[mc.gate + 1]
        \\      if mc.at == nil then
        \\        emu.write(AL.KL.real, g.met, wram)
        \\        emu.write(RAM_DOORIDX, g.door & 0xFF, wram)
        \\        emu.write(RAM_DOORIDX + 1, g.door >> 8, wram)
        \\        emu.write(RAM_TRANSDIR, MC.dir, wram)
        \\        mc.at = since
        \\        return
        \\      end
        \\      if rd16(RAM_DOORIDX, wram) ~= 0 then
        \\        if since - mc.at > GIVE_UP then emu.stop(223) end
        \\        return
        \\      end
        \\      -- The frames are phase 8's rule: this hook runs ahead of the pacer,
        \\      -- so the tick that wrote the index is the crossing's first.
        \\      if since - mc.at ~= g.frames then emu.stop(223) end
        \\      if emu.read(RAM_MAPIDX, wram) ~= g.bank or cell ~= g.cell then emu.stop(223) end
        \\      if emu.read(MC.tileTable, wram) ~= g.table then emu.stop(224) end
        \\      -- Step 22: and the room drawn through it is the one the ROM's
        \\      -- pointer names, not merely the operand. Three strips of sixteen
        \\      -- metatiles, so anything under a strip's worth compared is vacuous.
        \\      if checkEdge(CROSSINGS[1], rd16(RAM_CAMX, wram), rd16(RAM_CAMY, wram), MC.expand[mc.gate + 1], 227) < 64 then emu.stop(227) end
        \\      emu.write(RAM_TRANSDIR, 0, wram)
        \\      mc.gate, mc.at = mc.gate + 1, nil
        \\      return
        \\    end
        \\    -- **Then the quake.** One tick left on the countdown, at a count that
        \\    -- is not the Queen's: it must start on a frame whose counter's low
        \\    -- byte is zero, ask for the interruption, and run 255 steps on even
        \\    -- frames, shaking a pixel either way by the timer's bit 1. Halfway, a
        \\    -- door asks for a song, which must be held for the end rather than
        \\    -- asked for; at the end it is asked for and the driver's byte cleared.
        \\    -- Then once more from a count of $01, which is the Queen's length and
        \\    -- ends with no song held, so the isolated effect is ended instead.
        \\    local qt = emu.read(MC.quakeTimer, wram)
        \\    local fc = hud.logicFc()
        \\    if mc.q == nil then
        \\      emu.write(AL.KL.real, 0x46, wram)
        \\      emu.write(MC.quakeTimer, 0, wram)
        \\      emu.write(MC.songInt, 0, wram)
        \\      emu.write(MC.songPlaying, 0, wram)
        \\      emu.write(MC.afterQuake, 0, wram)
        \\      emu.write(MC.quakeNext, 1, wram)
        \\      mc.q, mc.at = 1, since
        \\      return
        \\    end
        \\    if mc.q == 1 then
        \\      if qt == 0 then
        \\        if emu.read(MC.quakeNext, wram) ~= 1 or since - mc.at > 300 then emu.stop(225) end
        \\        return
        \\      end
        \\      if fc ~= 0 or emu.read(MC.quakeNext, wram) ~= 0 then emu.stop(225) end
        \\      if emu.read(MC.songInt, wram) ~= MC.intQuake then emu.stop(225) end
        \\      if emu.read(MC.songPlaying, wram) ~= MC.intQuake then emu.stop(225) end
        \\      -- The tick's frame is even, so the shake has already run once.
        \\      if qt ~= MC.len - 1 then emu.stop(226) end
        \\      if emu.read(MC.shake, wram) ~= ((MC.len & MC.shakeBit) ~= 0 and 1 or 0xFF) then emu.stop(226) end
        \\      mc.q, mc.prev, mc.steps = 2, qt, 1
        \\      return
        \\    end
        \\    if mc.q == 2 then
        \\      if hud.owned then
        \\        -- The door interpreter's frames: no play handler, no quake.
        \\        if qt ~= mc.prev then emu.stop(226) end
        \\        if mc.door ~= nil and rd16(RAM_DOORIDX, wram) == 0 then
        \\          emu.write(RAM_TRANSDIR, 0, wram)
        \\          if emu.read(MC.afterQuake, wram) ~= MC.songId then emu.stop(228) end
        \\          if emu.read(AL.KL.song, wram) ~= mc.song0 then emu.stop(228) end
        \\          mc.doorDone = true
        \\        end
        \\      else
        \\        local even = (fc & 1) == 0
        \\        if qt ~= (even and mc.prev - 1 or mc.prev) then emu.stop(226) end
        \\        local pre = even and qt + 1 or qt
        \\        if emu.read(MC.shake, wram) ~= ((pre & MC.shakeBit) ~= 0 and 1 or 0xFF) then emu.stop(226) end
        \\        if even then mc.steps = mc.steps + 1 end
        \\      end
        \\      mc.prev = qt
        \\      if mc.steps == 0x80 and mc.door == nil then
        \\        -- A song other than the door's, so the restore is seen to change it.
        \\        mc.song0 = MC.songId ~ 1
        \\        emu.write(AL.KL.song, mc.song0, wram)
        \\        emu.write(RAM_DOORIDX, MC.songDoor & 0xFF, wram)
        \\        emu.write(RAM_DOORIDX + 1, MC.songDoor >> 8, wram)
        \\        emu.write(RAM_TRANSDIR, MC.dir, wram)
        \\        mc.door = since
        \\        return
        \\      end
        \\      if qt ~= 0 then return end
        \\      if not mc.doorDone or mc.steps ~= MC.len then emu.stop(226) end
        \\      if emu.read(MC.songPlaying, wram) ~= 0 then emu.stop(229) end
        \\      if emu.read(AL.KL.song, wram) ~= MC.songId or emu.read(MC.afterQuake, wram) ~= 0 then emu.stop(229) end
        \\      if emu.read(MC.songInt, wram) == MC.intEnd then emu.stop(229) end
        \\      emu.write(AL.KL.real, 0x01, wram)
        \\      emu.write(MC.songInt, 0, wram)
        \\      emu.write(MC.quakeNext, 1, wram)
        \\      mc.q, mc.at = 3, since
        \\      return
        \\    end
        \\    if mc.q == 3 then
        \\      if qt == 0 then
        \\        if since - mc.at > 300 then emu.stop(225) end
        \\        return
        \\      end
        \\      if qt ~= MC.lenLast - 1 then emu.stop(225) end
        \\      mc.q = 4
        \\      return
        \\    end
        \\    if mc.q == 5 then
        \\      -- **Step 22: the acid, standing in it.** A floor of the loaded
        \\      -- table's solid acid tile is laid under her, the way phase 26
        \\      -- lays a station, so her bottom-left probe reads acid on every
        \\      -- frame she stands. Measured on the any% run (frames 7369-7493):
        \\      -- a probe in acid loses `acidDamageValue` on the frames whose
        \\      -- counter is $x0 and on no others, once per probe, so 2 or 4 at a
        \\      -- damage of 2: 4 on the first tick, falling in, where both bottom
        \\      -- probes read non-solid acid, and 2 after, stood on the solid acid
        \\      -- floor, where the left probe stops the routine. James saw the same
        \\      -- 4-then-2 on every entry. Graded here is the standing half: the flag
        \\      -- every frame, exactly one damage on every $x0 frame, none between.
        \\      -- Then the entering half: 64 pixels of non-solid acid over the floor,
        \\      -- and she is lifted 48 into it just after a $x0 frame, so the next
        \\      -- tick lands mid-fall and must be 4, and the one after she lands 2.
        \\      local SV, ac = AL.SV, mc.ac
        \\      local function hp()
        \\        local lo, hi = emu.read(SV.healthLo, wram), emu.read(SV.healthLo + 1, wram)
        \\        return (lo >> 4) * 10 + (lo & 0xF) + ((hi >> 4) * 10 + (hi & 0xF)) * 100
        \\      end
        \\      local function each(f)
        \\        for r = ac.fr - 10, ac.fr + 1 do
        \\          for c = ac.fc - 3, ac.fc + 4 do f(r, ((r % 32) * 32 + (c % 32)) * 2) end
        \\        end
        \\      end
        \\      if ac == nil then
        \\        local solid = emu.read(SV.solid, wram)
        \\        local ptr = rd16(SV.colTab, wram) | (emu.read(SV.colTab + 2, wram) << 16)
        \\        local function byte(id) return emu.read(ptr + id, emu.memType.snesMemory) end
        \\        local id, air
        \\        for i = solid - 1, 4, -1 do if id == nil and (byte(i) & MC.blockAcid) ~= 0 then id = i end end
        \\        local liq
        \\        for i = solid, 0xFF do if air == nil and byte(i) == 0 then air = i end end
        \\        for i = solid, 0xFF do if liq == nil and (byte(i) & MC.blockAcid) ~= 0 then liq = i end end
        \\        if id == nil or air == nil or liq == nil then emu.stop(251) end
        \\        ac = {{ id = id, air = air, liq = liq, saved = {{}}, rest = 0, hits = 0, at = since,
        \\          fr = (((samy & 0xFF) + SV.bottom - 16) & 0xF8) // 8,
        \\          fc = (((samx & 0xFF) + SV.left - 8) & 0xF8) // 8,
        \\          items = emu.read(RAM_ITEMS, wram),
        \\          lo = emu.read(SV.healthLo, wram), hi = emu.read(SV.healthLo + 1, wram) }}
        \\        mc.ac = ac
        \\        each(function(r, o)
        \\          ac.saved[o] = emu.read(RAM_TILEMAP + o, wram)
        \\          emu.write(RAM_TILEMAP + o, r < ac.fr and air or id, wram)
        \\        end)
        \\        emu.write(RAM_ITEMS, 0, wram)            -- no Varia, which halves it
        \\        emu.write(RAM_POSE, POSE_STAND, wram)
        \\        emu.write(RAM_DOWNSPEED, 0, wram)
        \\        emu.write(MC.invuln, 0, wram)
        \\        -- The damage is the cart's own: `initialSaveFile`'s $02 through
        \\        -- `BootAcid`, or a gate door's `DAMAGE`. Zero is the Step 22
        \\        -- defect -- a fixture that forced 2 here passed a cart whose acid
        \\        -- took nothing off.
        \\        ac.dmg = emu.read(SV.acid, wram)
        \\        ac.dmg = (ac.dmg >> 4) * 10 + (ac.dmg & 0xF)
        \\        if ac.dmg == 0 then emu.stop(252) end
        \\        emu.write(SV.healthLo, 0x99, wram)
        \\        emu.write(SV.healthLo + 1, 0x01, wram)
        \\        ac.hp = hp()
        \\        return
        \\      end
        \\      if since - ac.at > GIVE_UP then emu.stop(252) end
        \\      local now, fc = hp(), hud.logicFc()
        \\      local on = emu.read(MC.acidContact, wram)
        \\      if ac.rest < 8 then
        \\        -- Landing and settling: not graded, only waited out.
        \\        if emu.read(RAM_POSE, wram) == POSE_STAND and on == 0x40 then ac.rest = ac.rest + 1 else ac.rest = 0 end
        \\        ac.hp = now
        \\        return
        \\      end
        \\      if on ~= 0x40 then emu.stop(251) end
        \\      local lost = ac.hp - now
        \\      ac.hp = now
        \\      if (fc & 0x0F) ~= 0 then
        \\        if lost ~= 0 then emu.stop(252) end
        \\        if ac.hits == 4 and ac.drop == nil and (fc & 0x0F) == 1 then
        \\          each(function(r, o) if r >= ac.fr - 8 and r < ac.fr then emu.write(RAM_TILEMAP + o, ac.liq, wram) end end)
        \\          local y = rd16(RAM_SAMY, wram) - 48
        \\          emu.write(RAM_SAMY, y & 0xFF, wram)
        \\          emu.write(RAM_SAMY + 1, (y >> 8) & 0xFF, wram)
        \\          emu.write(RAM_POSE, POSE_FALL, wram)
        \\          emu.write(RAM_DOWNSPEED, 0, wram)
        \\          ac.drop = since
        \\        end
        \\        return
        \\      end
        \\      local pose = emu.read(RAM_POSE, wram)
        \\      if ac.drop == nil then
        \\        if lost ~= ac.dmg then emu.stop(252) end
        \\      elseif ac.fallHit == nil then
        \\        -- Mid-fall in liquid acid: both bottom probes read it, 4.
        \\        if lost ~= 2 * ac.dmg or pose ~= POSE_FALL then emu.stop(254) end
        \\        ac.fallHit = since
        \\        return
        \\      else
        \\        -- Landed on the solid acid floor: the left probe stops it, 2.
        \\        if lost ~= ac.dmg or pose ~= POSE_STAND then emu.stop(254) end
        \\      end
        \\      ac.hits = ac.hits + 1
        \\      if ac.drop == nil or ac.fallHit == nil then return end
        \\      each(function(r, o) emu.write(RAM_TILEMAP + o, ac.saved[o], wram) end)
        \\      emu.write(RAM_ITEMS, ac.items, wram)
        \\      emu.write(SV.healthLo, ac.lo, wram)
        \\      emu.write(SV.healthLo + 1, ac.hi, wram)
        \\      enter(24, nil)
        \\      return
        \\    end
        \\    if qt ~= 0 then
        \\      if since - mc.at > 300 + 2 * MC.lenLast + 8 then emu.stop(229) end
        \\      return
        \\    end
        \\    if emu.read(MC.songInt, wram) ~= MC.intEnd or emu.read(MC.songPlaying, wram) ~= 0 then emu.stop(229) end
        \\    mc.q = 5
        \\
        \\  elseif phase == 24 then
        \\    -- **The room readout, Step 14.** A playtest aid, so what is graded is
        \\    -- that it stays out of the way and that it tells the truth: nothing on
        \\    -- the border and nothing owed for twenty-three phases with it off; L
        \\    -- and R together put BG1 on the border's band; the six tiles are the
        \\    -- map bank, the cell and the table the cart is in; a door relatches
        \\    -- them; and L and R again take the band away.
        \\    local RO, ro = AL.RO, al.ro
        \\    local function roShows(bank, c, tt)
        \\      local want = {{ bank, RO.colon, c >> 4, c & 15, -1, tt }}
        \\      for i = 1, 6 do
        \\        local a = (RO.map + RO.at + i - 1) * 2
        \\        local w = want[i] < 0 and 0 or RO.char + want[i]
        \\        if emu.read(a, vram) ~= w or emu.read(a + 1, vram) ~= 0 then return false end
        \\      end
        \\      return true
        \\    end
        \\    local function liveShows()
        \\      return roShows(emu.read(RAM_MAPIDX, wram) + 9, cell, emu.read(AL.MC.tileTable, wram))
        \\    end
        \\    if ro.step == nil then
        \\      if emu.read(RO.on, wram) ~= 0 or emu.read(RO.bandTm, wram) ~= 0 then emu.stop(230) end
        \\      if emu.read(RO.dirty, wram) ~= 0 then emu.stop(230) end
        \\      for i = 0, 5 do
        \\        if emu.read((RO.map + RO.at + i) * 2, vram) ~= 0 then emu.stop(230) end
        \\      end
        \\      hold = {{ l = true, r = true }}
        \\      ro.step, ro.at = 1, since
        \\      return
        \\    end
        \\    if ro.step == 1 or ro.step == 4 then
        \\      if since - ro.at == 3 then hold = nil end
        \\      if since - ro.at < 8 then return end
        \\      local on = ro.step == 1 and 1 or 0
        \\      if emu.read(RO.on, wram) ~= on or emu.read(RO.bandTm, wram) ~= on then emu.stop(231) end
        \\      if ro.step == 4 then enter(25, nil) return end
        \\      if not liveShows() then emu.stop(232) end
        \\      emu.write(AL.KL.real, 0x46, wram)
        \\      emu.write(RAM_DOORIDX, 0x4A, wram)
        \\      emu.write(RAM_DOORIDX + 1, 0, wram)
        \\      emu.write(RAM_TRANSDIR, AL.MC.dir, wram)
        \\      ro.step, ro.at = 2, since
        \\      return
        \\    end
        \\    if ro.step == 2 then
        \\      if rd16(RAM_DOORIDX, wram) ~= 0 then
        \\        if since - ro.at > GIVE_UP then emu.stop(232) end
        \\        return
        \\      end
        \\      emu.write(RAM_TRANSDIR, 0, wram)
        \\      ro.step, ro.at = 3, since
        \\      return
        \\    end
        \\    if since - ro.at < 3 then return end
        \\    -- `$F:$05`'s door, taken after a kill: `$B:$0C` through table 6.
        \\    if not roShows(0xB, 0x0C, 6) or not liveShows() then emu.stop(232) end
        \\    if emu.read(RO.dirty, wram) ~= 0 then emu.stop(232) end
        \\    hold = {{ l = true, r = true }}
        \\    ro.step, ro.at = 4, since
        \\
        \\  elseif phase == 25 then
        \\    -- **The spider ball, Step 14b.** A playtest could not reach the second
        \\    -- Alpha: Down in the ball with Spider Ball held did nothing, because
        \\    -- the arm tested Spring Ball's bit and the four poses had no
        \\    -- handlers. Graded here is what the recorded run cannot isolate: that
        \\    -- the entry is *gated*, as phase 10 grades the bomb jump; that a floor
        \\    -- reads as both bottom corners; that a roll is the spider's one pixel
        \\    -- a frame and never two, on one axis at a time; and that the pad and A
        \\    -- leave it. The climb itself is the recorded rung's, frame for frame.
        \\    local SP, sp = AL.SP, al.sp
        \\    local pose = emu.read(RAM_POSE, wram)
        \\    if sp.step == nil then
        \\      sp.items = emu.read(RAM_ITEMS, wram)
        \\      emu.write(RAM_ITEMS, sp.items & (0xFF ~ SP.item), wram)
        \\      sp.step, sp.at, sp.rest = 0, since, 0
        \\      -- **The ground is made here.** Phase 24's door leaves her where its
        \\      -- warp put her, and there the ball overlaps two solid tiles: every
        \\      -- probe reads solid, the nibble is $F, and the tables say an
        \\      -- embedded ball does not move -- which is the original's answer,
        \\      -- measured on this cart, and no use to a fixture. So two rows of
        \\      -- floor under her and five of air over it, eleven tiles wide, out of
        \\      -- ids whose collision byte is zero: nothing half-solid, no water,
        \\      -- no acid, only the solidity threshold.
        \\      local solid, ptr = emu.read(SP.solid, wram), rd16(SP.colTab, wram) | (emu.read(SP.colTab + 2, wram) << 16)
        \\      local function plain(id) return emu.read(ptr + id, emu.memType.snesMemory) == 0 end
        \\      for id = solid, 0xFF do if sp.air == nil and plain(id) then sp.air = id end end
        \\      for id = solid - 1, 4, -1 do if sp.floor == nil and plain(id) then sp.floor = id end end
        \\      if sp.air == nil or sp.floor == nil then emu.stop(233) end
        \\      local fr = (((samy & 0xFF) + SP.bottom - 16) & 0xF8) // 8
        \\      local fc = (((samx & 0xFF) + SP.left - 8) & 0xF8) // 8
        \\      for r = fr - 5, fr + 1 do
        \\        for c = fc - 2, fc + 8 do
        \\          local o = ((r % 32) * 32 + (c % 32)) * 2
        \\          emu.write(RAM_TILEMAP + o, r < fr and sp.air or sp.floor, wram)
        \\        end
        \\      end
        \\    end
        \\    local function at(step)
        \\      sp.step, sp.at, sp.px, sp.py, sp.moved = step, since, samx, samy, 0
        \\    end
        \\    local ago = since - sp.at
        \\    if sp.step == 0 then
        \\      -- The ball at rest, forced the way phase 10 forces it.
        \\      if pose ~= POSE_MORPH and pose ~= POSE_BALLFALL then emu.write(RAM_POSE, POSE_MORPH, wram) end
        \\      emu.write(RAM_DOWNSPEED, 0, wram)
        \\      if pose == POSE_MORPH and samy == sp.py then sp.rest = sp.rest + 1 else sp.rest = 0 end
        \\      sp.py = samy
        \\      if sp.rest >= 8 then at(1) hold = "down" return end
        \\      if ago > GIVE_UP then emu.stop(233) end
        \\    elseif sp.step == 1 then
        \\      hold = nil
        \\      if pose == SP.rest then emu.stop(233) end
        \\      if ago >= 8 then
        \\        emu.write(RAM_ITEMS, sp.items | SP.item, wram)
        \\        at(2) hold = "down" return
        \\      end
        \\    elseif sp.step == 2 then
        \\      hold = nil
        \\      if pose == SP.rest then at(3) return end
        \\      if ago >= 8 then emu.stop(234) end
        \\    elseif sp.step == 3 then
        \\      if pose ~= SP.rest then emu.stop(235) end
        \\      if ago >= 2 then
        \\        if emu.read(SP.contact, wram) ~= 0x0A then emu.stop(235) end
        \\        at(4) hold = "right" return
        \\      end
        \\    elseif sp.step == 4 then
        \\      local dx, dy = delta(samx, sp.px), delta(samy, sp.py)
        \\      if pose == SP.roll then
        \\        if dx + dy > 1 then emu.stop(236) end
        \\        sp.moved = sp.moved + dx + dy
        \\      end
        \\      sp.px, sp.py = samx, samy
        \\      if ago >= 24 then
        \\        if sp.moved < 8 then emu.stop(236) end
        \\        sp.step, sp.at = 5, since
        \\        hold = nil
        \\      end
        \\    elseif sp.step == 5 then
        \\      if ago == 3 then
        \\        if pose ~= SP.rest then emu.stop(237) end
        \\        hold = JUMP_BTN
        \\      elseif ago == 4 then
        \\        hold = nil
        \\      elseif ago == 7 then
        \\        if pose ~= POSE_MORPH and pose ~= POSE_BALLFALL then emu.stop(237) end
        \\        -- Now the landings: each pose written on a floor, with the
        \\        -- counter that pose flies a descent on, must attach within a
        \\        -- frame and clear the fall counter (00:$1241).
        \\        sp.step, sp.at = 7, since
        \\      end
        \\    elseif sp.step == 7 then
        \\      -- The bombed ball, $12, has its own Down arm in front of $11's
        \\      -- body; the port ran $11's handler for it until Step 14b.
        \\      -- A held button reaches the pose machine two frames on and a pose
        \\      -- written now runs on the next, so the press goes first. The answer
        \\      -- is $0C on the frame they meet: `$11`'s body would put her in the
        \\      -- falling ball, whose own Down arm reaches $0C only a frame later.
        \\      if ago == 1 then hold = "down"
        \\      elseif ago == 2 then emu.write(RAM_POSE, SP.bombed, wram) hold = nil
        \\      elseif ago == 3 then
        \\        if pose ~= SP.fall then emu.stop(239) end
        \\      elseif ago == 6 then
        \\        sp.land = {{ SP.fall, SP.jump }}
        \\        sp.step = 6
        \\      end
        \\    elseif sp.step == 6 then
        \\      if #sp.land == 0 then enter(26, nil) return end
        \\      if sp.wrote == nil then
        \\        if pose ~= POSE_MORPH then
        \\          emu.write(RAM_POSE, POSE_MORPH, wram)
        \\          return
        \\        end
        \\        emu.write(RAM_POSE, sp.land[1], wram)
        \\        emu.write(SP.fallArc, 5, wram)
        \\        emu.write(RAM_JUMPARC, JUMP_BASE + 0x16, wram)
        \\        sp.wrote = since
        \\        return
        \\      end
        \\      if since - sp.wrote >= 3 then
        \\        if pose ~= SP.roll and pose ~= SP.rest then emu.stop(238) end
        \\        if emu.read(SP.fallArc, wram) ~= 0 then emu.stop(238) end
        \\        table.remove(sp.land, 1)
        \\        sp.wrote = nil
        \\      end
        \\    end
        \\  elseif phase == 26 then
        \\    -- **The save station, Step 15a.** The cart had none: nothing set the
        \\    -- contact, Start on a station did nothing, and there was no cartridge
        \\    -- RAM to write. Graded here is the cart's half -- the contact, the
        \\    -- Start arm and its cooldown, the one frame the save takes, and that
        \\    -- the bytes in cartridge RAM are the live state in `save.fields`
        \\    -- order. That the *layout* is the game's is graded against the Game
        \\    -- Boy's own bytes, in `save.zig`.
        \\    local SV, sv = AL.SV, al.sv
        \\    local sram = emu.memType.snesSaveRam
        \\    local pose = emu.read(RAM_POSE, wram)
        \\    local function at(step) sv.step, sv.at = step, since end
        \\    local ago = since - (sv.at or since)
        \\    local function lay(id)
        \\      for r = sv.fr - 6, sv.fr + 1 do
        \\        for c = sv.fc - 3, sv.fc + 4 do
        \\          local o = ((r % 32) * 32 + (c % 32)) * 2
        \\          emu.write(RAM_TILEMAP + o, r < sv.fr and sv.air or id, wram)
        \\        end
        \\      end
        \\    end
        \\    if sv.step == nil then
        \\      local solid = emu.read(SV.solid, wram)
        \\      local ptr = rd16(SV.colTab, wram) | (emu.read(SV.colTab + 2, wram) << 16)
        \\      local function byte(id) return emu.read(ptr + id, emu.memType.snesMemory) end
        \\      for id = solid - 1, 4, -1 do
        \\        if sv.save == nil and byte(id) == SV.blockSave then sv.save = id end
        \\        if sv.plain == nil and byte(id) == 0 then sv.plain = id end
        \\      end
        \\      for id = solid, 0xFF do if sv.air == nil and byte(id) == 0 then sv.air = id end end
        \\      if sv.save == nil or sv.plain == nil or sv.air == nil then emu.stop(240) end
        \\      emu.write(RAM_ITEMS, 0, wram)
        \\      emu.write(RAM_POSE, POSE_STAND, wram)
        \\      emu.write(RAM_DOWNSPEED, 0, wram)
        \\      sv.fr = (((samy & 0xFF) + SV.bottom - 16) & 0xF8) // 8
        \\      sv.fc = (((samx & 0xFF) + SV.left - 8) & 0xF8) // 8
        \\      lay(sv.save)
        \\      sv.py, sv.rest = samy, 0
        \\      at(0)
        \\      return
        \\    end
        \\    if sv.step == 0 then
        \\      -- Standing still on the station's tiles.
        \\      if pose == POSE_STAND and samy == sv.py then sv.rest = sv.rest + 1 else sv.rest = 0 end
        \\      sv.py = samy
        \\      if ago > GIVE_UP then emu.stop(240) end
        \\      if sv.rest < 8 then return end
        \\      if emu.read(SV.contact, wram) ~= 0xFF then emu.stop(240) end
        \\      if emu.read(SV.cooldown, wram) ~= 0 then emu.stop(240) end
        \\      -- A clean cartridge RAM, a spawn window that says which flags the
        \\      -- writer touched, and live values no two fields share, so a field
        \\      -- read from the wrong source cannot come out equal by accident.
        \\      for i = 0, 0x1FFF do emu.write(i, 0, sram) end
        \\      sv.win = (emu.read(SV.prevBank, wram) - 9) * 0x40
        \\      local flags = {{ 0x02, 0xFE, 0x04, 0x05 }}
        \\      for i = 1, 4 do
        \\        emu.write(SV.spawnFlags + 0x40 + i - 1, flags[i], wram)
        \\        emu.write(SV.spawnSave + sv.win + i - 1, 0xAA, wram)
        \\      end
        \\      local pokes = {{ {{SV.beam, 0x03}}, {{SV.tanks, 0x02}}, {{SV.healthLo, 0x37}}, {{SV.healthLo + 1, 0x01}},
        \\        {{SV.maxMissLo, 0x55}}, {{SV.maxMissLo + 1, 0x00}}, {{SV.curMissLo, 0x44}}, {{SV.curMissLo + 1, 0x00}},
        \\        {{SV.acid, 0x11}}, {{SV.spike, 0x22}}, {{SV.igtMin, 0x12}}, {{SV.igtHours, 0x07}}, {{SV.song, 0x05}} }}
        \\      for _, p in ipairs(pokes) do emu.write(p[1], p[2], wram) end
        \\      emu.write(SV.sfx1, 0, wram)
        \\      hold = "start"
        \\      at(1)
        \\      return
        \\    end
        \\    if sv.step == 1 then
        \\      if ago == 1 then hold = nil end
        \\      if sv.dueAt == nil then
        \\        if emu.read(SV.due, wram) ~= 0 then
        \\          if emu.read(0, sram) ~= 0 then emu.stop(241) end
        \\          if emu.read(SV.cooldown, wram) ~= SV.cooldownN then emu.stop(241) end
        \\          sv.dueAt = since
        \\        elseif ago > 12 then emu.stop(241) end
        \\        return
        \\      end
        \\      -- The frame after: written, the request gone, and the cooldown not
        \\      -- yet ticked, because the play handler did not run.
        \\      if emu.read(SV.due, wram) ~= 0 then emu.stop(241) end
        \\      if emu.read(SV.cooldown, wram) ~= SV.cooldownN then emu.stop(241) end
        \\      if emu.read(SV.sfx1, wram) ~= SV.sfxSaved then emu.stop(241) end
        \\      local magic = {{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF }}
        \\      for i = 1, 8 do if emu.read(i - 1, sram) ~= magic[i] then emu.stop(242) end end
        \\      local want = {{}}
        \\      local function w(v) want[#want + 1] = v end
        \\      local function w16(a) w(emu.read(a, wram)) w(emu.read(a + 1, wram)) end
        \\      w16(RAM_SAMY) w16(RAM_SAMX) w16(SV.camY) w16(SV.camX)
        \\      for i = 8, 0x14 do w(emu.read(SV.buf + i, wram)) end
        \\      for _, a in ipairs({{ SV.items, SV.beam, SV.tanks, SV.healthLo, SV.healthLo + 1, SV.maxMissLo,
        \\        SV.maxMissLo + 1, SV.curMissLo, SV.curMissLo + 1, SV.facing, SV.acid, SV.spike, SV.metReal,
        \\        SV.song, SV.igtMin, SV.igtHours, SV.metDisp }}) do w(emu.read(a, wram)) end
        \\      for i = 1, #want do
        \\        if emu.read(7 + i, sram) ~= want[i] then emu.stop(242) end
        \\      end
        \\      -- The save buffer's pointers are the Game Boy's, not the port's ids:
        \\      -- a metatile table's pointer is in bank 8's window.
        \\      if emu.read(SV.buf + 0x0E, wram) < 0x40 then emu.stop(242) end
        \\      local base = 0x1000 + sv.win
        \\      local saved = {{ 0x02, 0xFE, 0xFE, 0xAA }}
        \\      for i = 1, 4 do if emu.read(base + i - 1, sram) ~= saved[i] then emu.stop(243) end end
        \\      emu.write(0, 0, sram)
        \\      at(2)
        \\      return
        \\    end
        \\    if sv.step == 2 then
        \\      -- Start again while the cooldown runs: nothing.
        \\      if ago == 4 then hold = "start" elseif ago == 5 then hold = nil end
        \\      if emu.read(SV.due, wram) ~= 0 or emu.read(0, sram) ~= 0 then emu.stop(244) end
        \\      if ago < 16 then return end
        \\      -- Off the station with the cooldown about to run out: cleared.
        \\      lay(sv.plain)
        \\      emu.write(SV.cooldown, 2, wram)
        \\      at(3)
        \\      return
        \\    end
        \\    if sv.step == 3 then
        \\      if ago < 6 then return end
        \\      if emu.read(SV.contact, wram) ~= 0 then emu.stop(245) end
        \\      -- And a door's transfer clears it, contact or cooldown.
        \\      emu.write(SV.contact, 0xFF, wram)
        \\      emu.write(SV.cooldown, 0x80, wram)
        \\      emu.write(RAM_DOORIDX, 0x4A, wram)
        \\      emu.write(RAM_DOORIDX + 1, 0, wram)
        \\      emu.write(RAM_TRANSDIR, AL.MC.dir, wram)
        \\      at(4)
        \\      return
        \\    end
        \\    if sv.step == 4 then
        \\      if rd16(RAM_DOORIDX, wram) ~= 0 then
        \\        if ago > GIVE_UP then emu.stop(245) end
        \\        return
        \\      end
        \\      emu.write(RAM_TRANSDIR, 0, wram)
        \\      -- The cooldown is the transfer's to clear and nothing else's; the
        \\      -- contact the collision may set again wherever the warp put her.
        \\      if emu.read(SV.cooldown, wram) ~= 0 then emu.stop(245) end
        \\      -- Step 17's scroll is last, because it is the one phase that
        \\      -- deliberately leaves the world somewhere the next phase would not
        \\      -- expect. Nothing follows it.
        \\      scroll = {{ frames = 0, moved = 0, ony = nil, onx = nil }}
        \\      startCrossing(1)
        \\      enter(27, nil)
        \\      return
        \\    end
        \\
        \\  elseif phase == 19 then
        \\    -- **Missiles, Step 13a.** A playtest pressed Select, heard nothing
        \\    -- change, and fired a dud: the cart had no missiles to fire. Five
        \\    -- stages, every number the cartridge's. Standing at rest with nothing
        \\    -- in the air; Select, which must switch the weapon, put the missile
        \\    -- cannon's tiles in VRAM and cost the frame `beginGraphicsTransfer`
        \\    -- waits; the fire button, which must launch a missile and spend one;
        \\    -- the fire button with none left, which must launch nothing and
        \\    -- ask for the dud; and Select back to the beam.
        \\    local function chrIs(want)
        \\      for i = 1, #want do
        \\        if emu.read(MS.cannonAt + i - 1, vram) ~= want[i] then return false end
        \\      end
        \\      return true
        \\    end
        \\    if ms.step == nil then
        \\      hold = nil
        \\      if liveProj() ~= nil or bm.live() ~= nil then return end
        \\      if since > 600 then emu.stop(201) end
        \\      if pose ~= POSE_STAND or samy ~= ms.y then
        \\        ms.y, ms.still = samy, since
        \\        return
        \\      end
        \\      if since - ms.still < 8 then return end
        \\      if emu.read(MS.weapon, wram) == MS.missile then emu.stop(198) end
        \\      if emu.read(MS.hold, wram) ~= 0 then emu.stop(200) end
        \\      -- Since Step 13b the HUD rolls the displayed health toward the real
        \\      -- one and asks for a tick of sound as it goes -- into the same
        \\      -- `sfxRequest_square1` the dud below is read from, as on the Game
        \\      -- Boy -- and phase 17 left the real health at $15 with the display
        \\      -- still at the new game's. Settle the roll first.
        \\      emu.write(HUD.dispH, emu.read(MS.health, wram), wram)
        \\      emu.write(HUD.dispH + 1, emu.read(MS.health + 1, wram), wram)
        \\      emu.write(MS.sfx1, 0, wram)
        \\      hold = "select"
        \\      ms.step, ms.at = 1, since
        \\      return
        \\    end
        \\    if ms.step == 1 then
        \\      -- The toggle's frame ends inside the wait: the hold is up at the
        \\      -- end of it, and down at the end of the next, which is the frame
        \\      -- the pass resumes on.
        \\      hold = nil
        \\      if emu.read(MS.hold, wram) ~= 0 then
        \\        if ms.holdAt ~= nil then emu.stop(200) end
        \\        ms.holdAt = since
        \\        if emu.read(MS.weapon, wram) ~= MS.missile then emu.stop(198) end
        \\        if emu.read(MS.sfx1, wram) ~= MS.sfxSelect then emu.stop(198) end
        \\        return
        \\      end
        \\      if ms.holdAt == nil then
        \\        -- Switched and never held: the weapon changed and no frame was spent.
        \\        if since - ms.at > 6 then
        \\          if emu.read(MS.weapon, wram) == MS.missile then emu.stop(200) end
        \\          emu.stop(198)
        \\        end
        \\        return
        \\      end
        \\      if since ~= ms.holdAt + 1 then emu.stop(200) end
        \\      if not chrIs(MS.missileChr) then emu.stop(199) end
        \\      if chrIs(MS.beamChr) then emu.stop(199) end
        \\      if liveProj() ~= nil then emu.stop(200) end
        \\      ms.count = rd16(MS.cur, wram)
        \\      hold = B5.fire
        \\      ms.step, ms.at, ms.holdAt = 2, since, nil
        \\      return
        \\    end
        \\    if ms.step == 2 then
        \\      hold = nil
        \\      local o = liveProj()
        \\      if o == nil then
        \\        if since - ms.at > 6 then emu.stop(201) end
        \\        return
        \\      end
        \\      if emu.read(o + B5.tType, wram) ~= MS.missile then emu.stop(201) end
        \\      -- One missile, in BCD: $30 is followed by $29, not $2F.
        \\      local want = tonumber(tostring(tonumber(string.format("%x", ms.count)) - 1), 16)
        \\      if rd16(MS.cur, wram) ~= want then emu.stop(202) end
        \\      ms.left = want
        \\      ms.step = 3
        \\      return
        \\    end
        \\    if ms.step == 3 then
        \\      if liveProj() ~= nil then return end
        \\      emu.write(MS.cur, 0, wram)
        \\      emu.write(MS.cur + 1, 0, wram)
        \\      emu.write(MS.sfx1, 0, wram)
        \\      hold = B5.fire
        \\      ms.step, ms.at = 4, since
        \\      return
        \\    end
        \\    if ms.step == 4 then
        \\      hold = nil
        \\      if liveProj() ~= nil then emu.stop(203) end
        \\      if since - ms.at < 6 then return end
        \\      if emu.read(MS.sfx1, wram) ~= MS.sfxDud then emu.stop(203) end
        \\      if rd16(MS.cur, wram) ~= 0 then emu.stop(203) end
        \\      hold = "select"
        \\      ms.step, ms.at = 5, since
        \\      return
        \\    end
        \\    hold = nil
        \\    if emu.read(MS.hold, wram) ~= 0 then return end
        \\    if since - ms.at < 4 then return end
        \\    if emu.read(MS.weapon, wram) ~= emu.read(MS.beam, wram) then emu.stop(198) end
        \\    if not chrIs(MS.beamChr) then emu.stop(199) end
        \\    -- Leave the count where the shot left it, for phase 18.
        \\    emu.write(MS.cur, ms.left & 0xFF, wram)
        \\    emu.write(MS.cur + 1, ms.left >> 8, wram)
        \\    enter(18, nil)
        \\
        \\  elseif phase == 27 then
        \\    -- **The scroll, Step 17, and the first thing in this repository to
        \\    -- grade it.** `TransitionCamera` (00:$0B44) walks the camera in at
        \\    -- four pixels a frame and drags Samus at one, and for those frames
        \\    -- the play handler skips the Samus block. What it does *not* skip is
        \\    -- the draw: the skip at 00:$0522 jumps to $053E and runs everything
        \\    -- from there, and `drawSamus` is at $0550, past it.
        \\    --
        \\    -- Measured on the Game Boy rather than argued from the addresses.
        \\    -- Across the any% run's vertical crossing at frames 1387-1420, $D03B
        \\    -- -- the on-screen Y `drawSamus` leaves and the sprite collision
        \\    -- reads -- moves on every frame: 122, 120, 117, 115 ... 37, and
        \\    -- reverses at 1421 when she walks. It is never still.
        \\    -- `zig build tas -- any 1430 1 watch:D03B,D03C` reproduces it.
        \\    --
        \\    -- So the assertion is that the pair moves, not that it holds any
        \\    -- particular value: the port's camera and position across a crossing
        \\    -- are already graded frame for frame by the `reachable` rung, and
        \\    -- what that rung cannot see is where she is *drawn*.
        \\    -- The script first: `startCrossing` wrote the index and the door
        \\    -- interpreter owns the frames until it clears it. `TransitionCamera`
        \\    -- is what runs after, on the direction the same write set.
        \\    if rd16(RAM_DOORIDX, wram) ~= 0 then
        \\      if since > GIVE_UP then emu.stop(250) end
        \\      return
        \\    end
        \\    local ony = emu.read(B5.onscreenY, wram)
        \\    local onx = emu.read(B5.triggerX, wram)
        \\    if scroll.ony ~= nil and (ony ~= scroll.ony or onx ~= scroll.onx) then
        \\      scroll.moved = scroll.moved + 1
        \\    end
        \\    scroll.ony, scroll.onx = ony, onx
        \\    scroll.frames = scroll.frames + 1
        \\    -- **The two animation timers, Step 24c.** 00:$0B44's first act is
        \\    -- `INC` on `$D072`, the spin counter the ball, the spider and the
        \\    -- spin jump draw from, and each of its four arms adds 3 to `$D022`,
        \\    -- the run cycle's (00:$0B60, $0B94, $0BC7, $0BFF). So the Game Boy's
        \\    -- sprite keeps turning through a crossing although the pose machine
        \\    -- is skipped. Measured on the any% run: across the ball crossing at
        \\    -- 708-716 `$D072` goes $59, $5A ... $61 and `$D022` $03, $06 ... $1B,
        \\    -- one step a frame, and the ball's OAM tile turns at 712 and 716;
        \\    -- during the script before it (609-707) both hold, because the
        \\    -- interpreter blocks. `zig build tas -- any 720 1
        \\    -- watch:D00E,D020,D022,D072,FE02` reproduces it.
        \\    --
        \\    -- Graded on the timers rather than the sprite because the phase
        \\    -- crosses standing, and the standing sprite reads neither -- but
        \\    -- every sprite that does is a function of these two and nothing
        \\    -- else. The one wrinkle is the run cycle's own clamp: `drawSamus_run`
        \\    -- (01:$4D77) writes zero back once the timer reaches $30, after the
        \\    -- camera's add, so a running crossing wraps where a standing one
        \\    -- does not.
        \\    local anim = emu.read(B5.animT, wram)
        \\    local spin = emu.read(B5.spinT, wram)
        \\    if scroll.anim ~= nil then
        \\      local want = (scroll.anim + 3) & 0xFF
        \\      if emu.read(RAM_POSE, wram) == B5.poseRun and want >= 0x30 then want = 0 end
        \\      if anim ~= want or spin ~= (scroll.spin + 1) & 0xFF then emu.stop(159) end
        \\    end
        \\    scroll.anim, scroll.spin = anim, spin
        \\    -- **An absent Samus is not this phase's to report.** `checkSprite`
        \\    -- already runs on every frame and its code 121 is "was not drawn at
        \\    -- all: nothing was composed into OAM" -- which is exactly what a
        \\    -- crossing without `DrawSamus` produces, because `!OamIdx` is zeroed
        \\    -- at the top of every frame and `ClearUnusedOam` hides the slots
        \\    -- nothing appended. Removing `jsr DrawSamus` from `.transitionFrame`
        \\    -- and running this phase exits 121, measured. A second assertion
        \\    -- saying the same thing would be a dead one.
        \\    -- **Bounded by frames, not by the scroll ending, and that is a fact
        \\    -- about the fixture rather than about the port.** `TransitionCamera`
        \\    -- stops when `CamX & $FF` *equals* `TRANS_STOP_*`, and this phase's
        \\    -- crossing is driven by writing a door index rather than by walking
        \\    -- into the clamp, so the camera's pixel half is wherever the warp
        \\    -- left it and need not be congruent to the stop value at all. Left
        \\    -- to run it scrolls for ever. The real game cannot reach that: the
        \\    -- trigger only fires with the camera on the clamp. So the phase
        \\    -- watches a window and then hands the direction back itself.
        \\    -- 24 frames: long enough that a drawn position which moves only on
        \\    -- the first frame cannot pass, short enough that the camera has not
        \\    -- walked far into the next room. A literal rather than a named
        \\    -- local because this chunk is at Lua's 200-local ceiling; see the
        \\    -- note on `scroll` above.
        \\    if scroll.frames < 24 then
        \\      if since > GIVE_UP then emu.stop(246) end
        \\      return
        \\    end
        \\    if emu.read(RAM_TRANSDIR, wram) == 0 then emu.stop(247) end
        \\    -- The Game Boy moves the pair on every frame of the scroll. Two are
        \\    -- allowed: the first sampled frame has nothing to compare against,
        \\    -- and the frame the direction clears is the camera's last.
        \\    -- **What this phase adds that the per-frame checks cannot.**
        \\    -- `checkSprite` compares the anchor with the camera guide, so it
        \\    -- catches a Samus who is absent or in the wrong place -- but a guide
        \\    -- that froze would freeze both and agree with itself. Only the
        \\    -- Game Boy says the pair must *move*, and it says it plainly.
        \\    --
        \\    -- **Not yet seen failing**, and that is worth stating rather than
        \\    -- implying: the fault this step was built for exits 121 before this
        \\    -- line is reached. It is here on the strength of the measurement,
        \\    -- not of a fixture that has caught something.
        \\    if scroll.moved < scroll.frames - 2 then emu.stop(248) end
        \\    -- Warp back, so B6 starts where it always has. The warp's operands
        \\    -- are absolute, which is what makes this safe -- see phase 8.
        \\    emu.write(RAM_TRANSDIR, 0, wram)
        \\    -- The sound (metroid2-audio Step 16b), as a **smoke check and no
        \\    -- more**: the engine ran `init` (`REPLY_ALIVE`, the shim's version,
        \\    -- at $3005) and has run ticks (`STATS__HOSTED_TICKS` at $0E18). What
        \\    -- it played is `audiocmp`'s and `audioparity`'s to grade. The shim's
        \\    -- ready byte itself is port 3's, which SPC RAM does not show.
        \\    local spc = emu.memType.spcRam
        \\    if emu.read(0x3005, spc) == 0 then emu.stop(249) end
        \\    if emu.read(0x0E18, spc) + emu.read(0x0E19, spc) == 0 then emu.stop(249) end
        \\    enter(28, nil)
        \\
        \\  elseif phase == 28 then
        \\    -- **The bar, Step 24g.** The last door is a save room's, so the item
        \\    -- font is resident and the window's second row holds " SAVE<>", as
        \\    -- on the Game Boy. Then a major item is collected through phase 9's
        \\    -- lever, the orb's two stores (02:$4E6D-$4E7C), because its jingle
        \\    -- raises the window on a screen that is lit here -- phase 9's
        \\    -- jingle and phase 26's station are both at brightness 0, and this
        \\    -- room's collision table has no station bit to lay one with. While it is up `hud.bar` grades both of the
        \\    -- window's rows: the status bar a row higher and the bar under it,
        \\    -- glyph for glyph. The station's own raise is code 1's, in phase 26.
        \\    if ITEMGFX.at > #ITEMGFX.doors then
        \\      local st = ITEMGFX.st
        \\      if st.at == nil then
        \\        emu.write(RAM_ITEMCOLLECTED, ITEM_NUMBER, wram)
        \\        emu.write(RAM_ITEMFLAG, 0xFF, wram)
        \\        st.at, hud.barRan = since, 0
        \\        return
        \\      end
        \\      local stage = emu.read(RAM_ITEMSTAGE, wram)
        \\      if stage ~= 0 then st.began = true end
        \\      hud.barRows = stage ~= 0 and 2 or nil
        \\      -- The orb's half of the handshake, as phase 9 stands in for it.
        \\      if emu.read(RAM_ITEMFLAG, wram) == 3 then
        \\        emu.write(RAM_ITEMFLAG, 0, wram)
        \\        emu.write(RAM_ITEMCOLLECTED, 0, wram)
        \\      end
        \\      if st.began and stage == 0 then
        \\        if hud.barRan < 16 then emu.stop(4) end
        \\        emu.stop(0)
        \\      end
        \\      if since - st.at > ITEM_WAIT + ITEM_JINGLE + 600 then emu.stop(4) end
        \\      return
        \\    end
        \\    -- **`ITEM`'s characters, Step 24.** The opcode's arm (00:$2618)
        \\    -- copies the orb to $8B00 and the item's four tiles to $8B40, and
        \\    -- until Step 24 the cart's copied nothing, so every orb and item
        \\    -- drew from the room's enemy sheet. Each door's script is run
        \\    -- through the same lever as phase 27, and then both depths of the
        \\    -- characters are compared with the ROM's bytes. Step 24b added a
        \\    -- door that loads an enemy sheet, the scrolling doors' usual copy.
        \\    --
        \\    -- **And the picture while the script runs, Step 24b.** None of
        \\    -- these doors fades, so the Game Boy shows the room, still, at
        \\    -- `$93` for every frame of the script. The cart held a forced blank
        \\    -- across all of them. Two checks, because two ways to be wrong were
        \\    -- measured: the frame ending blank or dimmed (128), and a band of
        \\    -- lines blanked for a copy and lifted before the frame ended, which
        \\    -- the register cannot show and the picture can (129). A row counts
        \\    -- as lit if any pixel in it is not black, and every row lit on the
        \\    -- frame before the trigger must stay lit.
        \\    local d = ITEMGFX.doors[ITEMGFX.at]
        \\    local buf = emu.getScreenBuffer()
        \\    local st = emu.getState()
        \\    local shown = not st["ppu.forcedBlank"] and st["ppu.screenBrightness"] == 15
        \\    if ITEMGFX.from == nil then
        \\      -- Phase 27's door fades, and it ends its scroll by clearing the
        \\      -- direction, which skips 00:$0C2B's fade back in: the room would
        \\      -- stay dark for good, which no play reaches. So the fade-in is
        \\      -- started here, once, as 00:$0C2B starts it, and the rows are
        \\      -- taken once the room is all the way up.
        \\      if not ITEMGFX.faded then
        \\        ITEMGFX.faded = true
        \\        if emu.read(ITEMGFX.bgp, wram) ~= ITEMGFX.normal then emu.write(ITEMGFX.fin, ITEMGFX.start, wram) end
        \\      end
        \\      if not shown then
        \\        if since > GIVE_UP then emu.stop(139) end
        \\        return
        \\      end
        \\      local same = true
        \\      for i = 1, #d.obj do
        \\        if emu.read(d.oa + i - 1, vram) ~= d.obj[i] then same = false break end
        \\      end
        \\      if same then emu.stop(139) end
        \\      ITEMGFX.lit = {{}}
        \\      for y = 0, VIEW_H - 1 do
        \\        for x = 0, VIEW_W - 1 do
        \\          if buf[(BAND_TOP + OVERSCAN + y) * 256 + WIN_LEFT + x + 1] & 0xFFFFFF ~= 0 then
        \\            ITEMGFX.lit[#ITEMGFX.lit + 1] = y
        \\            break
        \\          end
        \\        end
        \\      end
        \\      if #ITEMGFX.lit == 0 then emu.stop(129) end
        \\      emu.write(RAM_DOORIDX, d.door & 0xFF, wram)
        \\      emu.write(RAM_DOORIDX + 1, (d.door >> 8) & 0xFF, wram)
        \\      emu.write(RAM_TRANSDIR, 0, wram)
        \\      ITEMGFX.from = since
        \\      return
        \\    end
        \\    if not shown then emu.stop(128) end
        \\    for _, y in ipairs(ITEMGFX.lit) do
        \\      local lit = false
        \\      for x = 0, VIEW_W - 1 do
        \\        if buf[(BAND_TOP + OVERSCAN + y) * 256 + WIN_LEFT + x + 1] & 0xFFFFFF ~= 0 then lit = true break end
        \\      end
        \\      if not lit then emu.stop(129) end
        \\    end
        \\    if rd16(RAM_DOORIDX, wram) ~= 0 then
        \\      if since - ITEMGFX.from > GIVE_UP then emu.stop(139) end
        \\      return
        \\    end
        \\    for i = 1, #d.obj do
        \\      if emu.read(d.oa + i - 1, vram) ~= d.obj[i] then emu.stop(138) end
        \\    end
        \\    for i = 1, #d.bg do
        \\      if emu.read(d.ba + i - 1, vram) ~= d.bg[i] then emu.stop(138) end
        \\    end
        \\    -- Step 24g: `ITEM`'s fourth transfer, the name into the window's
        \\    -- second row (00:$26A0). A door without `ITEM` leaves it alone.
        \\    ITEMGFX.name = d.name or ITEMGFX.name
        \\    for i = 1, #(ITEMGFX.name or {{}}) do
        \\      if rd16(HUD.map + 64 + (i - 1) * 2, vram) ~= ITEMGFX.name[i] then emu.stop(3) end
        \\    end
        \\    ITEMGFX.at, ITEMGFX.from = ITEMGFX.at + 1, nil
        \\  end
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  -- Plus the ARAM upload's allowance (metroid2-audio Step 16a): ~60 frames
        \\  -- under forced blank before the title, measured at 59 in Mesen2.
        \\  if frames < 100 then return end
        \\  if phase == 0 then
        \\    checkBoot()
        \\    startScreenY = rd16(RAM_SAMY, wram) & 0xF00
        \\    enter(1, nil)
        \\    return
        \\  end
        \\  tick()
        \\end, emu.eventType.endFrame)
        \\
        \\emu.addEventCallback(function()
        \\  if type(hold) == "table" then emu.setInput(hold, 0)
        \\  elseif hold ~= nil then emu.setInput({{ [hold] = true }}, 0) end
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

/// The enemy phase 14 fires at, chosen by the cartridge rather than named here.
///
/// The lowest id with a nonzero `enemy_damage` entry -- that byte is the damage
/// the enemy does to *Samus*, and it is used here only because it is the test
/// `collision_projectileOneEnemy` opens with, so an id that failed it would
/// make the phase assert nothing -- and a hitbox pointer that lands inside the
/// hitbox blob. `dy`/`dx` place the enemy so its resolved box is centred on the
/// projectile's collision point, which is what makes the phase's placement
/// arithmetic the ROM's and not a guess about where a sprite is drawn.
const Target = struct { id: u8, dy: i16, dx: i16 };

fn targetEnemy(rom: []const u8) !Target {
    const dmg_e = offsets.find("enemy_damage") orelse return error.MissingEnemyDamage;
    const ptr_e = offsets.find("enemy_hitbox_pointers") orelse return error.MissingHitboxPointers;
    const box_e = offsets.find("enemy_hitboxes") orelse return error.MissingHitboxes;
    const dmg = rom[dmg_e.romOffset()..dmg_e.romEnd()];
    const ptrs = rom[ptr_e.romOffset()..ptr_e.romEnd()];
    const boxes = rom[box_e.romOffset()..box_e.romEnd()];

    var id: usize = 0;
    while (id < dmg.len) : (id += 1) {
        if (dmg[id] == 0) continue;
        if (id * 2 + 1 >= ptrs.len) continue;
        const ptr = @as(u16, ptrs[id * 2]) | (@as(u16, ptrs[id * 2 + 1]) << 8);
        if (ptr == entity.dead_pointer) continue;
        if (ptr < box_e.gb_addr) continue;
        const off = ptr - box_e.gb_addr;
        if (off + entity.hitbox_bytes > boxes.len) continue;
        const top: i16 = @as(i8, @bitCast(boxes[off]));
        const bot: i16 = @as(i8, @bitCast(boxes[off + 1]));
        const left: i16 = @as(i8, @bitCast(boxes[off + 2]));
        const right: i16 = @as(i8, @bitCast(boxes[off + 3]));
        // A record whose edges are the wrong way round would resolve to a box
        // no point is inside, and the phase would pass by never hitting.
        if (bot <= top or right <= left) continue;
        return .{
            .id = @intCast(id),
            .dy = -@divTrunc(top + bot, 2),
            .dx = -@divTrunc(left + right, 2),
        };
    }
    return error.NoTargetEnemy;
}

/// `weapon_damage`'s index for a bomb: 00:$3179's `LD A,$09`, which is what
/// `collision_bombOneEnemy` hands the damage pass.
const weapon_bomb: usize = 9;

/// A tile a bomb breaks, in the collision table the boot door's `COLLISION`
/// selects: the lowest id past the four hardcoded respawning ones whose byte has
/// the bomb bit (01:$5543) and **not** the shot bit (01:$5176), so the phase is
/// asking about the arm Step 12c added and not one a beam also reaches.
fn bombTile(rom: []const u8, ops: []const @import("door.zig").Op) !u8 {
    var col: ?u4 = null;
    for (ops) |op| switch (op) {
        .collision => |v| col = v,
        else => {},
    };
    const operand = col orelse return error.BootDoorSetsNoCollision;
    const order = tileset.collisionOrder(rom) orelse return error.UnresolvedCollision;
    const e = offsets.find(tileset.tilesets[order[operand]].collision) orelse return error.MissingCollision;
    const table = rom[e.romOffset()..e.romEnd()];
    const bomb = try blocks_mod.bombMask(rom);
    const shot = try blocks_mod.shotMask(rom);
    const first = try blocks_mod.compareAt(rom, 0x5536);
    var id: usize = first;
    while (id < table.len) : (id += 1) {
        if (table[id] & bomb != 0 and table[id] & shot == 0) return @intCast(id);
    }
    return error.NoBombTile;
}

/// `samus_bombPoseTable`'s entry for `pose`, out of the ROM at the address
/// 01:$551D's `LD HL,d16` names.
fn bombHitPose(rom: []const u8, pose: u8) !u8 {
    if (rom[0x551D] != 0x21) return error.NotTheBombPoseLoad;
    const addr = std.mem.readInt(u16, rom[0x551E..][0..2], .little);
    return rom[@as(usize, addr) + pose];
}

/// The enemy phase 18 bombs: the lowest id that does **no** damage to Samus and
/// has a hitbox record that resolves. Zero damage is the point twice over:
/// `collision_projectileOneEnemy` refuses such an enemy at 00:$320A and
/// `collision_bombOneEnemy` has no such test, and a touch from Samus against it
/// hurts nobody -- so the phase can put it beside her without a knockback
/// racing the explosion's.
const BombTarget = struct { id: u8, dy: i16, dx: i16, h: i16, w: i16 };

fn bombTarget(rom: []const u8) !BombTarget {
    const dmg_e = offsets.find("enemy_damage") orelse return error.MissingEnemyDamage;
    const ptr_e = offsets.find("enemy_hitbox_pointers") orelse return error.MissingHitboxPointers;
    const box_e = offsets.find("enemy_hitboxes") orelse return error.MissingHitboxes;
    const dmg = rom[dmg_e.romOffset()..dmg_e.romEnd()];
    const ptrs = rom[ptr_e.romOffset()..ptr_e.romEnd()];
    const boxes = rom[box_e.romOffset()..box_e.romEnd()];
    const metroid_lo = try blocks_mod.compareIn(rom, 2, 0x42D0);
    const metroid_hi = try blocks_mod.compareIn(rom, 2, 0x42D4);

    var id: usize = 1;
    while (id < dmg.len) : (id += 1) {
        if (dmg[id] != 0) continue;
        if (id >= metroid_lo and id < metroid_hi) continue;
        if (id * 2 + 1 >= ptrs.len) continue;
        const ptr = @as(u16, ptrs[id * 2]) | (@as(u16, ptrs[id * 2 + 1]) << 8);
        if (ptr == entity.dead_pointer) continue;
        if (ptr < box_e.gb_addr) continue;
        const off = ptr - box_e.gb_addr;
        if (off + entity.hitbox_bytes > boxes.len) continue;
        const top: i16 = @as(i8, @bitCast(boxes[off]));
        const bot: i16 = @as(i8, @bitCast(boxes[off + 1]));
        const left: i16 = @as(i8, @bitCast(boxes[off + 2]));
        const right: i16 = @as(i8, @bitCast(boxes[off + 3]));
        if (bot <= top or right <= left) continue;
        return .{
            .id = @intCast(id),
            .dy = -@divTrunc(top + bot, 2),
            .dx = -@divTrunc(left + right, 2),
            .h = @divTrunc(bot - top + 1, 2),
            .w = @divTrunc(right - left + 1, 2),
        };
    }
    return error.NoBombTarget;
}

/// The cold-boot test: does the cart a person picks up reach gameplay on its
/// own?
///
/// Deliberately a second, small script rather than another phase of the one
/// above. That one boots on a record `chooseBoot` invented so it has somewhere
/// to stand, drives Samus with a scripted pad and grades pixels; this one boots
/// the cart the builder ships and asks a single question with one button
/// pressed twice. Folding them together would mean the shipped cart and the
/// graded cart were the same cart, and they are not -- which is the whole point
/// of the mode byte in the record.
///
/// **What it is really testing is the absence of a lever.** Every other rung in
/// this repository pokes the cart into the state it wants to grade. Nothing
/// here does: it presses Start on the title the way a player does, watches the
/// appearance sequence, presses a direction when the game asks for one, and
/// watches Samus move.
/// How many OAM bytes the HUD icon's sprite `which` (0 or 1) composes: its part
/// count in Samus's set, off the ROM, at the id 01:$4B5A adds to.
fn iconBytes(rom: []const u8, which: u8) !u16 {
    const ptrs = offsets.find("metasprite_samus_pointers").?;
    const id = @as(usize, try blocks_mod.addAt(rom, 0x4B5A)) + which;
    const at = @as(usize, std.mem.readInt(u16, rom[ptrs.romOffset() + id * 2 ..][0..2], .little));
    var pos = blocks_mod.offsetIn(1, @intCast(at));
    var parts: u16 = 0;
    while (rom[pos] != entity.terminator) : (pos += entity.part_bytes) parts += 1;
    return parts * 4;
}

pub fn writeColdBoot(gpa: std.mem.Allocator, rom: []const u8, boot: screen.Boot, w: *std.Io.Writer) !void {
    // The title screen's characters and its tilemap, baked **from the Game Boy
    // ROM** rather than from the converted set. Comparing the cart against what
    // the converter produced would only say the DMA worked; comparing it
    // against the cartridge says the whole path did -- the four entries'
    // addresses, the order they are laid down in, and the rotation the
    // tilemap's ids are converted through.
    //
    // The run is one $1000-byte slice of the cartridge, taken **by address and
    // not by walking `inject.title_sheets`**. That distinction is the whole
    // value of the check: baking the expectation out of the same list the cart
    // is built from compares the cart against itself, and a sweep that reversed
    // the list passed. Taken this way, reversing it fails.
    //
    // The four entries tile this slice gaplessly -- `bank_005.asm` says the
    // title screen assumes they are contiguous, and `inject.titleRunLen`
    // re-derives it from the addresses so a fifth entry or a moved one is a
    // build failure rather than a wrong picture.
    const first = offsets.find(inject.title_sheets[0]) orelse return error.MissingTitleSheet;
    const run_len = inject.titleRunLen() orelse return error.MissingTitleSheet;
    // 2bpp characters convert byte for byte, so these bytes are also what VRAM
    // must hold; `snes_convert`'s "every converted character asset decodes back"
    // is what makes that a fact rather than an assumption.
    const run = rom[first.romOffset()..][0..run_len];
    _ = gpa;

    const map_entry = offsets.find(inject.title_map) orelse return error.MissingTitleMap;
    const ids = rom[map_entry.romOffset()..map_entry.romEnd()];

    // The tile id the Game Boy's copy destination names, which is the whole of
    // why the tilemap's ids rotate. `$8800` under the background's signed
    // addressing is id $80, so the run's k'th tile is id `base + k` and the
    // converted tilemap has to point id `n` at character `n - base`. Derived
    // through `snes_target`'s VRAM model -- the one the 904-screen render rung
    // grades -- rather than written down as 128.
    const base_id: u8 = switch (try target.gbDestToChar(target.gb_bg_window_lo)) {
        .chars => |c| @intCast(c),
        .tilemap, .window => return error.MissingTitleSheet,
    };

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The cold boot: the cart the builder ships, played rather than driven.
        \\--
        \\-- Exit codes:
        \\--   0  the cart reached gameplay from a cold boot
        \\-- 140  Fatal ran: the engine could not find something it was patched to find
        \\-- 141  the frame counter never advanced: the title screen is not running
        \\-- 142  the cart did not come up in the pose its record names
        \\-- 143  the countdown did not fall by exactly one a frame
        \\-- 144  control arrived before the countdown was spent
        \\-- 145  the countdown was spent and a held button never handed over control
        \\-- 146  the engine was handed a pose it could not run
        \\-- 147  Samus was drawn on every frame of the appearance sequence: no flicker
        \\-- 148  Samus was never drawn during the appearance sequence
        \\-- 149  control arrived and the pose machine did not move her
        \\-- 150  the title screen's characters are not the cartridge's
        \\-- 153  the title screen's tilemap does not name the characters it should
        \\-- 154  the title screen is in VRAM and not on the display
        \\-- 151  the title screen left on its own, with nothing pressed
        \\-- 152  Start did not leave the title screen
        \\-- 155  she drew over the ship where its colour is not 0: the start cell's
        \\--      transition word has bit 11, and the Game Boy puts her behind it
        \\-- 156  her parts covered no pixel of the ship's, or none of hers showed:
        \\--      155 graded nothing
        \\-- 157  no drawn frame followed a blank one in the appearance sequence
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local cgram = emu.memType.snesCgRam
        \\
        \\local RAM_FRAMES, RAM_POSE, RAM_UNHANDLED = {d}, {d}, {d}
        \\local RAM_COUNTDOWN, RAM_OAMIDX, RAM_SAMX = {d}, {d}, {d}
        \\local RAM_CELL = {d}
        \\local POSE_START, COUNTDOWN, CELL = {d}, {d}, {d}
        \\local WALK_BTN, START_BTN = "{s}", "{s}"
        \\
        \\local BASE_ID = {d}
        \\local VIEW_W, VIEW_H, WIN_LEFT, BAND_TOP = {d}, {d}, {d}, {d}
        \\local OVERSCAN = (239 - 224) // 2
        \\-- The HUD icon's OAM bytes, on each of its two sprites. Since Step 13b it
        \\-- is drawn on every frame of the sequence, the frames `drawSamus_faceScreen`
        \\-- declines included -- `drawHudMetroid` has its own call -- so a frame
        \\-- holding only the icon is one Samus was not drawn on.
        \\local ICON_A, ICON_B = {d}, {d}
        \\-- Step 24e: the Game Boy's first play row under the status bar, and
        \\-- where the engine keeps BGP, whose low two bits are colour 0's shade.
        \\BEHIND = {{ rows = {d}, bgp = {d}, blank = nil, at = nil, done = false }}
        \\
    , .{
        screen.ram.frame_count, screen.ram.pose,      screen.ram.unhandled,
        screen.ram.countdown,   screen.ram.oam_index, screen.ram.samus_x,
        screen.ram.cell,
        boot.pose,              boot.countdown,       boot.cell,
        "right",                "start",
        base_id,
        target.view_w,          target.view_h,
        screen.win_left,        screen.band_top,
        try iconBytes(rom, 0),  try iconBytes(rom, 1),
        try engineDefine("!HUD_WY         = $"), try engineDefine("!BgPalette    = $"),
    });
    try writeSramPrelude(w, &.{});

    // Before the callbacks, because a Lua closure captures the locals that
    // exist when it is created and these are read inside one.
    try writeBytes(w, "TITLE_CHR", run);
    try writeBytes(w, "TITLE_IDS", ids);

    try w.print(
        \\
        \\local function rd16(addr, kind) return emu.read(addr, kind) | (emu.read(addr + 1, kind) << 8) end
        \\
        \\-- The flicker, as a share rather than as a pattern. The original skips
        \\-- one frame in four, so an eighth in each direction refuses both a
        \\-- cart that never blanks and one that never draws while leaving the
        \\-- true ratio a wide berth -- and it is a *measurement*, where
        \\-- reproducing `frameCounter & 3` in Lua would only be this script
        \\-- agreeing with the engine's bugs as readily as with its correctness.
        \\-- A quarter was tried first and sits exactly on the real ratio, which
        \\-- makes it a coin toss on the rounding.
        \\local MIN_SHARE = 8
        \\
        \\local function shade(px)
        \\  local r = (px >> 16) & 0xFF
        \\  if r > 200 then return 0 elseif r > 120 then return 1
        \\  elseif r > 40 then return 2 else return 3 end
        \\end
        \\
        \\-- Step 24e. The ship's cell has bit 11 of its transition word set, so on
        \\-- the Game Boy every part of hers carries OAM bit 7 there (00:$3ED5,
        \\-- 01:$4BA1) and the ship's colours 1-3 cover her. The appearance
        \\-- sequence is the one stretch where she flickers and nothing else moves,
        \\-- so the blank frame before a drawn one is the ship alone. Inside her
        \\-- parts, wherever that frame shows a shade other than colour 0's, the
        \\-- background has a non-zero index and the drawn frame must be the same.
        \\-- Her parts are the PPU's OAM entries above the status bar; the icon's
        \\-- are below it. A row either side of each part, so an off-by-one in
        \\-- the sprite line only adds pixels that are the ship's on both frames.
        \\function behindCheck(buf, pair)
        \\  local oam = emu.memType.snesSpriteRam
        \\  local bgp = emu.read(BEHIND.bgp, wram)
        \\  local over, seen, parts = 0, 0, 0
        \\  for i = 0, 127 do
        \\    local x = emu.read(i * 4, oam)
        \\    local y = emu.read(i * 4 + 1, oam)
        \\    local ninth = (emu.read(512 + (i >> 2), oam) >> ((i & 3) * 2)) & 1
        \\    if ninth == 0 and y >= BAND_TOP and y < BAND_TOP + BEHIND.rows then
        \\      parts = parts + 1
        \\      for dy = -1, 8 do
        \\        local wy = y + dy - BAND_TOP
        \\        if wy >= 0 and wy < BEHIND.rows then
        \\          for dx = 0, 7 do
        \\            local wx = x + dx - WIN_LEFT
        \\            if pair and wx >= 0 and wx < VIEW_W then
        \\              local k = (BAND_TOP + OVERSCAN + wy) * 256 + WIN_LEFT + wx + 1
        \\              local was, now = BEHIND.blank[k], buf[k]
        \\              if now ~= was then seen = seen + 1 end
        \\              if shade(was) ~= (bgp & 3) then
        \\                over = over + 1
        \\                if now ~= was then emu.stop(155) end
        \\              end
        \\            end
        \\          end
        \\        end
        \\      end
        \\    end
        \\  end
        \\  return parts, over, seen
        \\end
        \\
        \\local frames, phase, since, checked = 0, 0, 0, false
        \\local drawn, blank, prevCd, startX = 0, 0, nil, nil
        \\local hold = nil
        \\
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  -- Boot runs under forced blank with NMI off until the title screen
        \\  -- turns both on, so nothing below is meaningful for the first few
        \\  -- frames. Ten was not enough and reported "boot never finished" for
        \\  -- a cart that boots.
        \\  -- Plus the ARAM upload's allowance (metroid2-audio Step 16a): ~60 frames
        \\  -- under forced blank before the title, measured at 59 in Mesen2.
        \\  if frames < 120 then return end
        \\  if rd16(0, cgram) == 0x7C1F then emu.stop(140) end
        \\  if emu.read(RAM_UNHANDLED, wram) ~= 0 then emu.stop(146) end
        \\
        \\  local pose = emu.read(RAM_POSE, wram)
        \\  local cd = rd16(RAM_COUNTDOWN, wram)
        \\  since = since + 1
        \\
        \\  if phase == 0 then
        \\    -- The title screen. NMI is on, so the frame counter is running;
        \\    -- `InitState` has not, so the cell the record names is not in the
        \\    -- engine's state yet. Those two together are what says the cart is
        \\    -- *on* the title rather than stalled in front of it.
        \\    if rd16(RAM_FRAMES, wram) < 5 then emu.stop(141) end
        \\    if emu.read(RAM_CELL, wram) == CELL then emu.stop(151) end
        \\
        \\    -- And the title screen is on it, character for character and word
        \\    -- for word    -- against the cartridge's own bytes. Once: it is 4096 reads and 1024
        \\    -- more, and neither can change while the title is up.
        \\    if not checked then
        \\      for i = 1, #TITLE_CHR do
        \\        if emu.read(i - 1, vram) ~= TITLE_CHR[i] then emu.stop(150) end
        \\      end
        \\      for i = 1, #TITLE_IDS do
        \\        local want = (TITLE_IDS[i] - BASE_ID) & 0xFF
        \\        if (rd16(0x1000 + (i - 1) * 2, vram) & 0x3FF) ~= want then emu.stop(153) end
        \\      end
        \\      -- And it is actually on the display, not merely in VRAM. A cart with
        \\      -- the right characters, a blank forced on it and a scroll pointing
        \\      -- somewhere else passes every check above and shows a black screen.
        \\      -- The title is mostly backdrop with a large logo on it, so a
        \\      -- fiftieth of the window is a floor no correct picture can fail
        \\      -- and no blank one can reach.
        \\      local buf = emu.getScreenBuffer()
        \\      local corner = buf[(BAND_TOP + OVERSCAN) * 256 + WIN_LEFT + 1]
        \\      local lit = 0
        \\      for y = 0, VIEW_H - 1 do
        \\        for x = 0, VIEW_W - 1 do
        \\          if buf[(BAND_TOP + OVERSCAN + y) * 256 + WIN_LEFT + x + 1] ~= corner then lit = lit + 1 end
        \\        end
        \\      end
        \\      if lit * 50 < VIEW_W * VIEW_H then emu.stop(154) end
        \\      checked = true
        \\    end
        \\
        \\    -- Twenty frames with nothing held. The original leaves the title
        \\    -- on Start's rising edge and on nothing else, so a cart that walks
        \\    -- off it by itself is a cart that never had a title.
        \\    if since >= 20 then
        \\      -- A blank cartridge RAM, said rather than inherited: since Step
        \\      -- 15b the title reads slot 0, and Mesen keeps a `.srm` between
        \\      -- runs. A slot this does not clear could make this a load.
        \\      for i = 0, 0x1FFF do emu.write(i, 0, emu.memType.snesSaveRam) end
        \\      hold, phase, since = START_BTN, 1, 0
        \\    end
        \\    return
        \\  end
        \\
        \\  if phase == 1 then
        \\    -- Start is held for a few frames and then let go, because the
        \\    -- original reads the *edge*: a hold that never ends would also
        \\    -- satisfy the button the appearance sequence waits for, and this
        \\    -- rung would stop testing that it waits.
        \\    if since == 4 then hold = nil end
        \\    if emu.read(RAM_CELL, wram) ~= CELL then
        \\      if since > 180 then emu.stop(152) end
        \\      return
        \\    end
        \\    -- Boot finished and the record is in the engine's state.
        \\    if pose ~= POSE_START then emu.stop(142) end
        \\    -- Seeded, and *already ticking*. The rest of boot runs with NMI
        \\    -- off, so there are frames where the counter is seeded and has
        \\    -- not moved -- and starting the one-a-frame check on one of those
        \\    -- read a stalled counter as a broken one. A record that left the
        \\    -- counter at zero never gets past this, which is the check that
        \\    -- was wanted: without it every phase below passes vacuously.
        \\    if cd == 0 or cd >= COUNTDOWN then
        \\      if since > 180 then emu.stop(143) end
        \\      return
        \\    end
        \\    prevCd, phase, since = cd, 2, 0
        \\    return
        \\  end
        \\
        \\  if phase == 2 then
        \\    -- The appearance sequence. She stays in the pose, the counter falls
        \\    -- by exactly one a frame, and she is drawn on three frames in four.
        \\    if pose ~= POSE_START then emu.stop(144) end
        \\    if cd ~= prevCd - 1 then emu.stop(143) end
        \\    prevCd = cd
        \\    local used = rd16(RAM_OAMIDX, wram)
        \\    if used == ICON_A or used == ICON_B then blank = blank + 1 else drawn = drawn + 1 end
        \\    if not BEHIND.done then
        \\      local buf = emu.getScreenBuffer()
        \\      local pair = BEHIND.at ~= nil and BEHIND.at == frames - 1
        \\      local parts, over, seen = behindCheck(buf, pair)
        \\      if parts == 0 then
        \\        BEHIND.blank, BEHIND.at = buf, frames
        \\      elseif pair then
        \\        if over == 0 or seen == 0 then emu.stop(156) end
        \\        BEHIND.done = true
        \\      end
        \\    end
        \\    if cd == 0 then
        \\      if not BEHIND.done then emu.stop(157) end
        \\      if blank * MIN_SHARE < drawn + blank then emu.stop(147) end
        \\      if drawn * MIN_SHARE < drawn + blank then emu.stop(148) end
        \\      phase, since = 3, 0
        \\    end
        \\    return
        \\  end
        \\
        \\  if phase == 3 then
        \\    -- Spent, and nothing held. `loadingFromFile` is zero on a new game,
        \\    -- so the original waits here for a button and so must the port: a
        \\    -- cart that hands over on the timer alone passes every check above.
        \\    if pose ~= POSE_START then emu.stop(144) end
        \\    if since >= 20 then
        \\      hold, phase, since = WALK_BTN, 4, 0
        \\    end
        \\    return
        \\  end
        \\
        \\  if phase == 4 then
        \\    -- A button is held. Control arrives, and the pose the original
        \\    -- forces is standing.
        \\    if pose == POSE_START then
        \\      if since > 10 then emu.stop(145) end
        \\      return
        \\    end
        \\    startX, phase, since = rd16(RAM_SAMX, wram), 5, 0
        \\    return
        \\  end
        \\
        \\  -- Playing. The direction is still held, so the pose machine has to
        \\  -- move her -- which is what says the cart reached the game rather
        \\  -- than a state that merely stopped being pose ${X:0>2}.
        \\  if rd16(RAM_SAMX, wram) ~= startX then emu.stop(0) end
        \\  if since > 120 then emu.stop(149) end
        \\end, emu.eventType.endFrame)
        \\
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput({{ [hold] = true }}, 0) end
        \\end, emu.eventType.inputPolled)
        \\
    , .{boot.pose});
}

/// What the load rung puts in slot 0, and what it expects of the cart.
pub const LoadMode = enum {
    /// James's first save, byte for byte: the cart must come up in it.
    load,
    /// The same record with its energy changed and the expectations not: the
    /// rung must fail, on code 164.
    energy_fault,
    /// A record with the magic intact that the title's broken check refuses,
    /// because its first bytes agree with the ROM past the magic until one the
    /// check reads as below $08. The cart must start a new game.
    accident,
};

/// The title's slot check as 05:$426D-$4288 runs it, over the ROM bytes that
/// follow `saveFile_magicNumber` and a slot: true when it calls the slot a game.
pub fn slotIsGame(rom: []const u8, slot: []const u8) bool {
    var i: usize = 0;
    while (true) : (i += 1) {
        const b = rom[save.magic_addr + i];
        const s = if (i < slot.len) slot[i] else 0xFF;
        if (s != b) return b >= 0x08;
    }
}

/// A spawn number in the saved half of the flags ($40 and up: Metroids and
/// items, which stay gone) somewhere in the record's bank. The half is loaded a
/// bank at a time, so any of them says whether the bank's window came back.
fn savedSpawn(rom: []const u8, bank: u8) !u8 {
    const ptr_e = offsets.find("enemy_data_pointers") orelse return error.MissingSpawns;
    const data_e = offsets.find("enemy_data") orelse return error.MissingSpawns;
    const ptrs = rom[ptr_e.romOffset()..ptr_e.romEnd()];
    const data = rom[data_e.romOffset()..data_e.romEnd()];
    const base = (@as(usize, bank) - 9) * entity.screens_per_bank;
    for (0..entity.screens_per_bank) |c| {
        const ptr = std.mem.readInt(u16, ptrs[(base + c) * 2 ..][0..2], .little);
        var at: usize = ptr - data_e.gb_addr;
        while (data[at] != entity.terminator) : (at += entity.spawn_bytes) {
            if (data[at] >= 0x40) return data[at];
        }
    }
    return error.NoSavedSpawn;
}

/// The load: slot 0 holds a record, the title's Start reads it, and the cart
/// comes up where the record says with what it says. Step 15b.
pub fn writeLoadBoot(gpa: std.mem.Allocator, rom: []const u8, boot: screen.Boot, mode: LoadMode, w: *std.Io.Writer) !void {
    var slot: [save.record_len]u8 = save.recorded_save;
    const want = save.parseInitial(save.recorded_save[save.magic_len..]).?;
    switch (mode) {
        .load => {},
        .energy_fault => slot[32] = if (slot[32] == 0x42) 0x43 else 0x42,
        .accident => {
            const run = rom[save.magic_addr..];
            var k: usize = save.magic_len;
            while (run[k] >= 0x08) : (k += 1) slot[k] = run[k];
            slot[k] = run[k] ^ 0xFF;
        },
    }
    const loads = slotIsGame(rom, &slot);
    if (loads != (mode != .accident)) return error.SlotCheckModel;

    const bank = want.level_bank;
    const killed = try savedSpawn(rom, bank);
    var spawn: [entity.spawn_banks * 0x40]u8 = @splat(0xFF);
    spawn[(@as(usize, bank) - 9) * 0x40 + killed - 0x40] = 0x02;

    // What VRAM must hold: the record's background source, byte for byte at
    // 2bpp, and the item font as objects over the enemy page.
    const bg_at = @as(usize, want.bg_gfx_bank) * offsets.bank_size + (want.bg_gfx_src & 0x3FFF);
    const bg = rom[bg_at..][0..@import("screens.zig").load_bg_len];
    const bg_vram = @as(u32, (try target.gbDestToChar(@import("screens.zig").load_bg_dest)).wordAddr()) * 2;
    const font_copy = convert.loadGraphicsCopy(rom, convert.load_font_at) orelse return error.MissingFont;
    const font_at = @as(usize, font_copy.bank) * offsets.bank_size + (font_copy.src & 0x3FFF);
    const font = try @import("snes_chr.zig").to4bpp(gpa, rom[font_at..][0..font_copy.len]);
    defer gpa.free(font);
    const font_vram = @as(u32, try target.gbDestToObj(font_copy.dest)) * 2;
    // And the common item tiles, which 00:$05FD copies to $8F00 on a load and
    // on a new game alike. $8F00 is in the window the Game Boy's objects and
    // background share, so the missile door's F4-F6, the drops and the item
    // orb draw from them as objects: at 4bpp in the object characters too.
    const common_copy = convert.loadGraphicsCopy(rom, convert.load_common_at) orelse return error.MissingCommonItems;
    if (!target.inSharedWindow(common_copy.dest)) return error.MissingCommonItems;
    const common_at = @as(usize, common_copy.bank) * offsets.bank_size + (common_copy.src & 0x3FFF);
    const common = try @import("snes_chr.zig").to4bpp(gpa, rom[common_at..][0..common_copy.len]);
    defer gpa.free(common);
    const common_vram = @as(u32, try target.gbDestToObj(common_copy.dest)) * 2;

    const sym = struct {
        fn f(name: []const u8) !u32 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.f;

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The load, Step 15b: slot 0 holds a record ({s}), Start on the title
        \\-- reads it, and the cart comes up in it.
        \\--
        \\-- Exit codes:
        \\--   0  the cart did what the slot says
        \\-- 160  Fatal ran
        \\-- 161  the title screen never ran
        \\-- 162  Start did not leave the title
        \\-- 163  the room, position or camera is not the record's
        \\-- 164  energy, tanks or missiles are not the record's
        \\-- 165  items, beam or facing are not the record's
        \\-- 166  the Metroid counts are not the record's
        \\-- 167  an enemy the record says is dead is not
        \\-- 168  the background characters are not the record's source
        \\-- 169  the item font is not in the object characters
        \\-- 170  control waited for a button after a load
        \\-- 171  the file counter was not written, or the title decided wrongly
        \\-- 172  the engine was handed a pose it could not run
        \\-- 173  the solidity or the metatile table is not the record's
        \\-- 174  the common item tiles are not in the object characters
        \\
    , .{@tagName(mode)});
    try writeSramPrelude(w, &.{});
    try w.print(
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local sram  = emu.memType.snesSaveRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr, kind) return emu.read(addr, kind) | (emu.read(addr + 1, kind) << 8) end
        \\
        \\local R = {{ frames = {d}, pose = {d}, unhandled = {d}, countdown = {d}, cell = {d}, map = {d},
        \\  samx = {d}, samy = {d}, camx = {d}, camy = {d}, health = {d}, dispHealth = {d}, tanks = {d},
        \\  maxMiss = {d}, curMiss = {d}, items = {d}, beam = {d}, weapon = {d}, facing = {d},
        \\  metReal = {d}, metDisp = {d}, spawnFlags = {d}, solid = {d}, solidEnemy = {d},
        \\  solidBeam = {d}, tileTable = {d}, loading = {d} }}
        \\
    , .{
        try sym("VarFrameCount"), try sym("VarPose"),       try sym("VarUnhandled"),
        try sym("VarCountdown"),  try sym("VarCell"),       try sym("VarMapIndex"),
        try sym("VarSamusX"),     try sym("VarSamusY"),     try sym("VarCamX"),
        try sym("VarCamY"),       try sym("VarHealthLo"),   try sym("VarDispHealthLo"),
        try sym("VarTanks"),      try sym("VarMaxMissLo"),  try sym("VarCurMissLo"),
        try sym("VarItems"),      try sym("VarBeam"),       try sym("VarActiveWeapon"),
        try sym("VarFacing"),     try sym("VarMetReal"),    try sym("VarMetDisp"),
        try sym("VarSpawnFlags"), try sym("VarSolid"),      try sym("VarSolidEnemy"),
        try sym("VarSolidBeam"),  try sym("VarTileTable"),  try sym("VarLoadingFromFile"),
    });
    try w.print(
        \\local LOADS = {s}
        \\local POSE_START, COUNTDOWN = {d}, {d}
        \\local NEW_CELL, NEW_MAP = {d}, {d}
        \\local KILLED = {d}
        \\local BG_VRAM, FONT_VRAM, COMMON_VRAM = {d}, {d}, {d}
        \\
    , .{
        if (loads) "true" else "false",
        boot.pose,                boot.countdown,
        boot.cell,                boot.map_index,
        killed,
        bg_vram,                  font_vram,
        common_vram,
    });
    // The record as `save.zig` reads it, and the metatile table by pointer.
    try w.print(
        \\local WANT = {{ map = {d}, cell = {d}, samx = {d}, samy = {d}, camx = {d}, camy = {d},
        \\  health = {d}, tanks = {d}, maxMiss = {d}, curMiss = {d}, items = {d}, beam = {d},
        \\  facing = {d}, metReal = {d}, metDisp = {d}, solid = {d}, solidEnemy = {d}, solidBeam = {d} }}
        \\
    , .{
        bank - 9,           want.cell(),            want.samus_x,     want.samus_y,
        want.cam_x,         want.cam_y,             want.health,      want.energy_tanks,
        want.max_missiles,  want.missiles,          want.items,       want.beam,
        want.facing,        want.metroid_count_real, want.metroid_count_displayed,
        want.samus_solidity, want.enemy_solidity,   want.beam_solidity,
    });
    const tt = blk: {
        const e = offsets.find("metatile_pointers") orelse return error.MissingTable;
        const ptrs = rom[e.romOffset()..e.romEnd()];
        var i: usize = 0;
        while (i * 2 < ptrs.len) : (i += 1) {
            if (std.mem.readInt(u16, ptrs[i * 2 ..][0..2], .little) == want.tiletable_src) break :blk i;
        }
        return error.MissingTable;
    };
    try w.print("WANT.tileTable = {d}\n", .{tt});
    try writeBytes(w, "SLOT", &slot);
    try writeBytes(w, "SPAWN", &spawn);
    try writeBytes(w, "BG", bg);
    try writeBytes(w, "FONT", font);
    try writeBytes(w, "COMMON", common);

    try w.print(
        \\
        \\local frames, phase, since, hold, spent = 0, 0, 0, nil, nil
        \\
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  -- Plus the ARAM upload's allowance (metroid2-audio Step 16a): ~60 frames
        \\  -- under forced blank before the title, measured at 59 in Mesen2.
        \\  if frames < 120 then return end
        \\  if rd16(0, cgram) == 0x7C1F then emu.stop(160) end
        \\  if emu.read(R.unhandled, wram) ~= 0 then emu.stop(172) end
        \\  since = since + 1
        \\  local pose = emu.read(R.pose, wram)
        \\
        \\  if phase == 0 then
        \\    if rd16(R.frames, wram) < 5 then emu.stop(161) end
        \\    -- The cartridge RAM a player's cart would hold: the slot, a file
        \\    -- counter the title must overwrite, and the spawn flags.
        \\    for i = 0, 0x1FFF do emu.write(i, 0, sram) end
        \\    for i = 1, #SLOT do emu.write(i - 1, SLOT[i], sram) end
        \\    emu.write(0xC0, 0x55, sram)
        \\    for i = 1, #SPAWN do emu.write(0x1000 + i - 1, SPAWN[i], sram) end
        \\    hold, phase, since = "start", 1, 0
        \\    return
        \\  end
        \\
        \\  if phase == 1 then
        \\    if since == 4 then hold = nil end
        \\    -- Boot runs under forced blank with NMI off and frames still end,
        \\    -- so the pose and the countdown are seeded several frames before
        \\    -- the load has finished. A countdown that has started to fall is
        \\    -- the first frame `MainLoop` has run.
        \\    local cd = rd16(R.countdown, wram)
        \\    if pose ~= POSE_START or cd == 0 or cd >= COUNTDOWN then
        \\      if since > 180 then emu.stop(162) end
        \\      return
        \\    end
        \\    if emu.read(0xC0, sram) ~= 0 then emu.stop(171) end
        \\    for i = 1, #COMMON do
        \\      if emu.read(COMMON_VRAM + i - 1, vram) ~= COMMON[i] then emu.stop(174) end
        \\    end
        \\    if not LOADS then
        \\      -- The title called the slot empty: a new game, as a blank cart.
        \\      if emu.read(R.loading, wram) ~= 0 then emu.stop(171) end
        \\      if emu.read(R.cell, wram) ~= NEW_CELL or emu.read(R.map, wram) ~= NEW_MAP then emu.stop(171) end
        \\      emu.stop(0)
        \\      return
        \\    end
        \\    if emu.read(R.loading, wram) ~= 0xFF then emu.stop(171) end
        \\    if emu.read(R.map, wram) ~= WANT.map or emu.read(R.cell, wram) ~= WANT.cell then emu.stop(163) end
        \\    if rd16(R.samx, wram) ~= WANT.samx or rd16(R.samy, wram) ~= WANT.samy then emu.stop(163) end
        \\    if rd16(R.camx, wram) ~= WANT.camx or rd16(R.camy, wram) ~= WANT.camy then emu.stop(163) end
        \\    if rd16(R.health, wram) ~= WANT.health or rd16(R.dispHealth, wram) ~= WANT.health then emu.stop(164) end
        \\    if emu.read(R.tanks, wram) ~= WANT.tanks then emu.stop(164) end
        \\    if rd16(R.maxMiss, wram) ~= WANT.maxMiss or rd16(R.curMiss, wram) ~= WANT.curMiss then emu.stop(164) end
        \\    if emu.read(R.items, wram) ~= WANT.items then emu.stop(165) end
        \\    if emu.read(R.beam, wram) ~= WANT.beam or emu.read(R.weapon, wram) ~= WANT.beam then emu.stop(165) end
        \\    if emu.read(R.facing, wram) ~= WANT.facing then emu.stop(165) end
        \\    if emu.read(R.metReal, wram) ~= WANT.metReal or emu.read(R.metDisp, wram) ~= WANT.metDisp then emu.stop(166) end
        \\    if emu.read(R.solid, wram) ~= WANT.solid or emu.read(R.solidEnemy, wram) ~= WANT.solidEnemy
        \\      or emu.read(R.solidBeam, wram) ~= WANT.solidBeam then emu.stop(173) end
        \\    if emu.read(R.tileTable, wram) ~= WANT.tileTable then emu.stop(173) end
        \\    if emu.read(R.spawnFlags + KILLED, wram) ~= 0x02 then emu.stop(167) end
        \\    for i = 1, #BG do
        \\      if emu.read(BG_VRAM + i - 1, vram) ~= BG[i] then emu.stop(168) end
        \\    end
        \\    for i = 1, #FONT do
        \\      if emu.read(FONT_VRAM + i - 1, vram) ~= FONT[i] then emu.stop(169) end
        \\    end
        \\    phase, since = 2, 0
        \\    return
        \\  end
        \\
        \\  if phase == 2 then
        \\    -- The appearance sequence runs out, and with nothing held control
        \\    -- arrives anyway: 00:$0EBD, `loadingFromFile`.
        \\    if pose == POSE_START then
        \\      if rd16(R.countdown, wram) == 0 then
        \\        spent = spent or since
        \\        if since - spent > 10 then emu.stop(170) end
        \\      end
        \\      if since > 400 then emu.stop(170) end
        \\      return
        \\    end
        \\    phase, since = 3, 0
        \\    return
        \\  end
        \\
        \\  -- A second of play in the room, and the enemy is still dead.
        \\  if emu.read(R.spawnFlags + KILLED, wram) ~= 0x02 then emu.stop(167) end
        \\  if since >= 60 then emu.stop(0) end
        \\end, emu.eventType.endFrame)
        \\
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput({{ [hold] = true }}, 0) end
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

/// Samus's death on the shipped cart, Step 15c: twice from a new game, once
/// left on the game over screen's timer and once on Start, each graded by length
/// against `src/death.zig`'s measurement of the Game Boy, with the erase, the
/// GAME OVER screen and the reboot to the title checked on the way.
pub const DeathRun = enum {
    /// The Game Boy's lengths: the cart must match them.
    grade,
    /// Mode $05 expected three frames longer than the Game Boy's: the rung must
    /// fail, on code 185, or it is not comparing anything.
    length_fault,
};

pub fn writeDeathBoot(gpa: std.mem.Allocator, rom: []const u8, boot: screen.Boot, run: DeathRun, w: *std.Io.Writer) !void {
    _ = gpa;
    const sym = struct {
        fn f(name: []const u8) !u32 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.f;
    const first = offsets.find(inject.title_sheets[0]) orelse return error.MissingTitleSheet;
    const run_len = inject.titleRunLen() orelse return error.MissingTitleSheet;
    const title_chr = rom[first.romOffset()..][0..run_len];
    const map_entry = offsets.find(inject.title_map) orelse return error.MissingTitleMap;
    const title_ids = rom[map_entry.romOffset()..map_entry.romEnd()];
    const erase_e = offsets.find("deathAnimationTable") orelse return error.MissingTable;
    const erase = rom[erase_e.romOffset()..erase_e.romEnd()];
    const text_e = offsets.find("gameOverText") orelse return error.MissingTable;
    const text = rom[text_e.romOffset()..text_e.romEnd()];

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- Samus's death, Step 15c: the shipped cart, played to a death twice.
        \\--
        \\-- Exit codes:
        \\--   0  both deaths ran the Game Boy's course and rebooted to the title
        \\-- 180  Fatal ran
        \\-- 181  the title or the new game never arrived
        \\-- 182  zero displayed health did not kill her, or mode $06 did not follow a frame later
        \\-- 183  mode $06 is not the Game Boy's length
        \\-- 184  the erase zeroed the wrong bytes, or not all of the object characters
        \\-- 185  mode $05 is not the Game Boy's length, or the screen was not blank for its frames
        \\-- 186  the GAME OVER screen is not the title's characters, the cleared map and the text, or the window is on
        \\-- 187  mode $07 on its timer is not the Game Boy's length
        \\-- 188  the reboot did not reach the title, or cartridge RAM did not survive it
        \\-- 189  Start on the game over screen did not reboot when the Game Boy's does
        \\-- 190  the engine was handed a pose it could not run
        \\-- 191  the pad moved Samus on the frame she died
        \\-- 192  a Start held through the reboot left the title, or a fresh Start did not
        \\-- 193  the title after the death did not open as a cold boot's does: the
        \\--      option hidden, clear unselected, slot 0 and the cursor on START
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local sram  = emu.memType.snesSaveRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr, kind) return emu.read(addr, kind) | (emu.read(addr + 1, kind) << 8) end
        \\
        \\local R = {{ frames = {d}, pose = {d}, unhandled = {d}, countdown = {d}, samx = {d},
        \\  health = {d}, dispHealth = {d}, mode = {d}, timer = {d}, blank = {d}, bands = {d} }}
        \\local RESUME, DYING, DEAD, OVER = {d}, {d}, {d}, {d}
        \\local POSE_START, COUNTDOWN = {d}, {d}
        \\local BAND_HUD, TM_PLAY = {d}, {d}
        \\local OBJ_VRAM, STEPS, STRIDE, STRIDES = {d}, {d}, {d}, {d}
        \\local TEXT_AT = {d}
        \\-- Step 24h. The title's three bytes, the shadow, and the cursor's row as
        \\-- the shadow holds it (START's y, moved into the band).
        \\TITLE = {{ show = {d}, sel = {d}, slot = {d}, oam = {d}, row = {d}, hidden = {d} }}
        \\
    , .{
        try sym("VarFrameCount"), try sym("VarPose"),         try sym("VarUnhandled"),
        try sym("VarCountdown"),  try sym("VarSamusX"),       try sym("VarHealthLo"),
        try sym("VarDispHealthLo"), try sym("VarDeathMode"),  try sym("VarDeathTimer"),
        try sym("VarDeathBlank"), try sym("VarBands"),
        try sym("ConstDeathResume"), death.mode_dying,        death.mode_dead,
        death.mode_game_over,
        boot.pose,                boot.countdown,
        try sym("ConstBandHud"),  try sym("ConstTmPlay"),
        @as(u32, target.obj_char_base) * 2, erase.len,        0x20,
        0x800 / 0x20,
        ((try sym("ConstGameOverRow")) * 32 + (try sym("ConstGameOverCol"))) * 2,
        try sym("VarTitleShowClear"), try sym("VarTitleClearSel"), try sym("VarActiveSlot"),
        try sym("VarOamBuf"),
        (try sym("ConstTitleStartY")) + screen.band_top - physics.oam_y_ofs,
        try engineDefine("!OAM_HIDDEN_Y = $"),
    });
    try writeSramPrelude(w, &.{});
    // The Game Boy's lengths, and the Start press it was measured with.
    const t = death.on_timer;
    const st = death.on_start;
    const press = death.start_press.start;
    try w.print(
        \\local GB = {{ kill = {d}, dying = {d}, dead = {d}, blank = {d}, over = {d}, onTimer = {d}, onStart = {d} }}
        \\local PRESS_AFTER, PRESS_HOLD = {d}, {d}
        \\-- A length is the Game Boy's within 2%, and never tighter than a frame:
        \\-- the frame a mode changes on moves with where in a frame each machine's
        \\-- vblank falls (`src/death.zig`).
        \\local function close(got, want) return math.abs(got - want) <= math.max(1, want * 2 // 100) end
        \\local REPORT = nil
        \\
    , .{
        t.dying,     t.dyingLen(), t.deadLen() + @as(u32, if (run == .length_fault) 3 else 0), t.blankLen(), t.game_over, t.gameOverLen(),
        st.gameOverLen(), press.after, press.hold,
    });
    try writeBytes(w, "TITLE_CHR", title_chr);
    try writeBytes(w, "TITLE_IDS", title_ids);
    try writeBytes(w, "ERASE", erase);
    try writeBytes(w, "TEXT", text);

    try w.print(
        \\
        \\local frames, phase, since, hold, run = 0, 0, 0, nil, 1
        \\local d = nil
        \\
        \\local function titleUp()
        \\  for i = 1, #TITLE_IDS do
        \\    if (rd16(0x1000 + (i - 1) * 2, vram) & 0x3FF) ~= ((TITLE_IDS[i] + 0x80) & 0xFF) then return false end
        \\  end
        \\  return true
        \\end
        \\
        \\local function stride(v)
        \\  for k = 0, STRIDES - 1 do
        \\    if emu.read(OBJ_VRAM + v + k * STRIDE, vram) ~= 0 then return false end
        \\  end
        \\  return true
        \\end
        \\
        \\local function gameOverScreen()
        \\  for i = 1, #TITLE_CHR do
        \\    if emu.read(i - 1, vram) ~= TITLE_CHR[i] then return false end
        \\  end
        \\  local n = 0
        \\  while TEXT[n + 1] ~= 0x80 do n = n + 1 end
        \\  for i = 0, 1023 do
        \\    local want = 0x7F
        \\    local o = i * 2 - TEXT_AT
        \\    if o >= 0 and o < n * 2 then want = (TEXT[o // 2 + 1] + 0x80) & 0xFF end
        \\    if rd16(0x1000 + i * 2, vram) ~= want then return false end
        \\  end
        \\  return emu.read(R.bands + BAND_HUD, wram) == TM_PLAY
        \\end
        \\
        \\local function report(name, v) if REPORT == name then emu.stop(v & 0xFF) end end
        \\
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  if frames < 40 then return end
        \\  if rd16(0, cgram) == 0x7C1F then emu.stop(180) end
        \\  if emu.read(R.unhandled, wram) ~= 0 then emu.stop(190) end
        \\  since = since + 1
        \\  local pose = emu.read(R.pose, wram)
        \\
        \\  if phase == 0 then
        \\    -- The title: a blank cartridge RAM, but for a byte past every
        \\    -- record, which the reboot must leave alone.
        \\    if rd16(R.frames, wram) < 5 or not titleUp() then
        \\      if since > 300 then emu.stop(run == 1 and 181 or 188) end
        \\      return
        \\    end
        \\    if run == 1 then
        \\      for i = 0, 0x1FFF do emu.write(i, 0, sram) end
        \\      emu.write(0x1FFF, 0x5A, sram)
        \\    elseif emu.read(0x1FFF, sram) ~= 0x5A then emu.stop(188) end
        \\    hold, phase, since = "start", 1, 0
        \\    return
        \\  end
        \\
        \\  if phase == 1 then
        \\    if since == 4 then hold = nil end
        \\    if pose ~= POSE_START then
        \\      if since > 600 then emu.stop(181) end
        \\      return
        \\    end
        \\    if rd16(R.countdown, wram) ~= 0 then return end
        \\    hold, phase, since = "right", 2, 0
        \\    return
        \\  end
        \\
        \\  if phase == 2 then
        \\    if pose == POSE_START then
        \\      if since > 30 then emu.stop(181) end
        \\      return
        \\    end
        \\    if since < 40 then return end
        \\    -- Dead: both health pairs, the displayed one because it is what
        \\    -- 00:$04EC tests and the real one so the HUD does not roll it back.
        \\    for i = 0, 1 do
        \\      emu.write(R.health + i, 0, wram)
        \\      emu.write(R.dispHealth + i, 0, wram)
        \\    end
        \\    -- And the title's bytes left as a visit that showed CLEAR and held
        \\    -- Down would leave them. The Game Boy's reboot clears $D000-$DFFF
        \\    -- (00:$01FB), so the title opens as a cold boot's; code 193.
        \\    emu.write(TITLE.show, 0xFF, wram)
        \\    emu.write(TITLE.sel, 0x01, wram)
        \\    d = {{ at = since }}
        \\    local any = false
        \\    for i = 0, 0x7FF do if emu.read(OBJ_VRAM + i, vram) ~= 0 then any = true break end end
        \\    if not any then emu.stop(184) end
        \\    phase = 3
        \\    return
        \\  end
        \\
        \\  if phase == 3 then
        \\    local mode = emu.read(R.mode, wram)
        \\    local now = since
        \\    if d.kill == nil then
        \\      if mode ~= RESUME then
        \\        if now - d.at > 3 then emu.stop(182) end
        \\        return
        \\      end
        \\      d.kill, d.x = now, rd16(R.samx, wram)
        \\      return
        \\    end
        \\    if d.dying == nil then
        \\      if mode ~= DYING then emu.stop(182) end
        \\      d.dying = now
        \\      report("kill", d.dying - d.kill)
        \\      if not close(d.dying - d.kill, GB.kill) then emu.stop(182) end
        \\      if rd16(R.samx, wram) ~= d.x then emu.stop(191) end
        \\      d.timer = emu.read(R.timer, wram)
        \\      return
        \\    end
        \\    if d.dead == nil then
        \\      -- One step of the erase per timer tick: the stride that step names
        \\      -- is zero across all of the object characters.
        \\      local timer = emu.read(R.timer, wram)
        \\      if timer ~= d.timer then
        \\        if timer ~= d.timer - 1 then emu.stop(184) end
        \\        if not stride(ERASE[timer + 1]) then emu.stop(184) end
        \\        d.timer = timer
        \\      end
        \\      if mode == DYING then
        \\        if now - d.dying > 200 then emu.stop(183) end
        \\        return
        \\      end
        \\      if mode ~= DEAD then emu.stop(183) end
        \\      d.dead = now
        \\      report("dying", d.dead - d.dying)
        \\      if not close(d.dead - d.dying, GB.dying) then emu.stop(183) end
        \\      for i = 0, 0x7FF do if emu.read(OBJ_VRAM + i, vram) ~= 0 then emu.stop(184) end end
        \\      hold = nil
        \\      return
        \\    end
        \\    if d.over == nil then
        \\      local blank = emu.read(R.blank, wram)
        \\      if blank ~= 0 and d.blank == nil then d.blank = now end
        \\      if mode == DEAD then
        \\        if now - d.dead > 120 then emu.stop(185) end
        \\        return
        \\      end
        \\      if mode ~= OVER or d.blank == nil then emu.stop(185) end
        \\      d.over = now
        \\      report("dead", d.over - d.dead)
        \\      report("blank", d.over - d.blank)
        \\      if not close(d.over - d.dead, GB.dead) then emu.stop(185) end
        \\      if d.over - d.blank ~= GB.blank then emu.stop(185) end
        \\      if not gameOverScreen() then emu.stop(186) end
        \\      return
        \\    end
        \\    if mode == OVER then
        \\      if run == 2 then
        \\        if now == d.over + PRESS_AFTER - 1 then hold = "start" end
        \\        if now == d.over + PRESS_AFTER + PRESS_HOLD - 1 then hold = nil end
        \\      end
        \\      if now - d.over > 400 then emu.stop(run == 1 and 187 or 189) end
        \\      return
        \\    end
        \\    -- Rebooted: `Reset` cleared the mode with the rest of work RAM.
        \\    if mode ~= 0 then emu.stop(188) end
        \\    local len = now - d.over
        \\    if run == 1 then
        \\      report("onTimer", len)
        \\      if not close(len, GB.onTimer) then emu.stop(187) end
        \\    else
        \\      report("onStart", len)
        \\      if not close(len, GB.onStart) then emu.stop(189) end
        \\    end
        \\    d = nil
        \\    -- The second reboot comes with Start still down, as the Game Boy's
        \\    -- did when it was measured; it stays down past the title's arrival.
        \\    if run == 2 then hold, phase, since = "start", 4, 0 return end
        \\    hold = nil
        \\    run, phase, since = 2, 0, 0
        \\    return
        \\  end
        \\
        \\  -- After the second: the title again, with the save byte kept. A Start
        \\  -- held from before the reboot is not a press (the Game Boy's boot
        \\  -- frame reads it, `death.zig`), so the title stays; a fresh one leaves.
        \\  if since == 30 then hold = nil end
        \\  if phase == 4 then
        \\    if since < 150 then return end
        \\    if rd16(R.frames, wram) < 5 then emu.stop(188) end
        \\    if emu.read(0x1FFF, sram) ~= 0x5A then emu.stop(188) end
        \\    if not titleUp() then emu.stop(192) end
        \\    if emu.read(TITLE.show, wram) ~= 0 or emu.read(TITLE.sel, wram) ~= 0
        \\      or emu.read(TITLE.slot, wram) ~= 0 then emu.stop(193) end
        \\    local onStart = false
        \\    for i = 0, 127 do
        \\      local tile = emu.read(TITLE.oam + i * 4 + 2, wram)
        \\      if emu.read(TITLE.oam + i * 4 + 1, wram) == TITLE.row and tile >= 0xED and tile <= 0xEF then onStart = true end
        \\    end
        \\    if not onStart then emu.stop(193) end
        \\    hold, phase, since = "start", 5, 0
        \\    return
        \\  end
        \\  if since == 4 then hold = nil end
        \\  if titleUp() then
        \\    if since > 120 then emu.stop(192) end
        \\    return
        \\  end
        \\  emu.stop(0)
        \\end, emu.eventType.endFrame)
        \\
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput({{ [hold] = true }}, 0) end
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

/// The round trip, Step 15d: the shipped cart played from its title through a
/// save, a death and a load, with the state it comes back in graded against the
/// record it wrote on the way out.
///
/// **Composed from the three rungs before it rather than repeating them.** The
/// station and the writer are Step 15a's, the death is Step 15c's and the
/// title's slot check and the load are Step 15b's; what is new here is that the
/// record the cart *wrote* is the thing the load is graded against. Every rung
/// before this one hands the cart a record the gate invented.
///
/// **Two things it sets rather than plays**, both named so neither is mistaken
/// for something graded: the Metroid count, because reaching `$46` honestly
/// means killing an Alpha and that is Step 13d's phases, not a title boot; and
/// the station's tiles, laid from the loaded collision table the way phase 26
/// lays them, because the cart holds one converted cell and it is not a station.
/// The collision byte's save-station bit, `BIT 7,A` at both of
/// `collision_samusBottom`'s probes. `room.block_save` is the same bit and
/// `correspond.zig` derives it from those instructions.
const block_save: u8 = 0x80;

pub const RoundTrip = enum {
    /// The record comes back: the rung must pass.
    grade,
    /// The slot's energy byte is changed after the record is captured and
    /// before the death, so the load brings back a different number than the
    /// record said. The rung must fail, on code 207, or it is comparing
    /// nothing.
    energy_fault,
    /// Step 24i. The same trip in slot 2, chosen on the title with one Left
    /// (0 wraps to 2): the record and its spawn flags land at slot 2's
    /// offsets and nowhere else, Start writes 2 to `saveLastSlot`, the reboot
    /// opens the title on slot 2 from it, and the load reads slot 2 back.
    slot2,

    fn slot(r: RoundTrip) u8 {
        return if (r == .slot2) 2 else 0;
    }
};

pub fn writeRoundTrip(gpa: std.mem.Allocator, rom: []const u8, cart: inject.Rom, boot: screen.Boot, run: RoundTrip, w: *std.Io.Writer) !void {
    _ = gpa;
    const sym = struct {
        fn f(name: []const u8) !u32 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.f;
    const map_entry = offsets.find(inject.title_map) orelse return error.MissingTitleMap;
    const title_ids = rom[map_entry.romOffset()..map_entry.romEnd()];

    // **Which collision table the rung stands her on, and why it is not the
    // one the cart boots with.** A station's tile is a collision byte with bit
    // 7 set, and scanned across the eight tables in the retail ROM only four
    // have one: `caveFirst` (ids 16-19), `plantBubbles`, `lavaCaves` and
    // `ruinsInside`. `surface`, which the cart's boot cell uses, has none --
    // which is a fact about the game and not about the port, and is why the
    // recording's five saves are all in `caveFirst` rooms. So the rung points
    // `!ColTab` at a table that has a station, writing the same address the
    // engine's own `.collFound` stores after `FindBlob` (engine/main.asm).
    const station = blk: {
        var id: u8 = 0;
        while (id < 16) : (id += 1) {
            const bytes = inject.blobBytes(cart, .collision, id) orelse continue;
            for (bytes, 0..) |b, tile| {
                if (b & block_save == 0) continue;
                const at = inject.blobAddress(cart, .collision, id) orelse continue;
                break :blk .{ .addr = at, .tile = @as(u8, @intCast(tile)) };
            }
        }
        return error.NoCollisionTableHasAStation;
    };

    // The new game's own count, so "not a new game's" is the cartridge's number
    // and not one written down here.
    const new_game = save.initial(rom) orelse return error.MissingInitialSave;

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The round trip, Step 15d ({s}): the cart saves, dies, and loads back
        \\-- the record it wrote.
        \\--
        \\-- Exit codes:
        \\--   0  the cart came back in the record it had written
        \\-- 200  Fatal ran
        \\-- 201  the title or the new game never arrived
        \\-- 202  the save station's tiles did not set the contact
        \\-- 203  Start on the station did not write a record
        \\-- 204  the death did not reach the title, or cartridge RAM did not survive it
        \\-- 205  the title refused the record it had just written
        \\-- 206  the room, position or camera is not the record's
        \\-- 207  energy, tanks or missiles are not the record's
        \\-- 208  the Metroid counts are not the record's, or are a new game's
        \\-- 209  items, beam or facing are not the record's
        \\-- 210  the engine was handed a pose it could not run
        \\-- 211  control never arrived after the load
        \\-- 212  the loaded collision table has no save station tile in it
        \\-- 213  Left on the title did not select the slot the run saves in (Step 24i)
        \\-- 214  the save wrote outside its slot, its spawn flags are not the buffer's,
        \\--      or `saveLastSlot` is not the slot
        \\-- 215  the title after the reboot did not open on the saved slot, or the
        \\--      load's spawn flags are not that slot's
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local sram  = emu.memType.snesSaveRam
        \\local cgram = emu.memType.snesCgRam
        \\local vram  = emu.memType.snesVideoRam
        \\local function rd16(addr, kind) return emu.read(addr, kind) | (emu.read(addr + 1, kind) << 8) end
        \\
    , .{@tagName(run)});
    try writeSramPrelude(w, &.{});

    try w.print(
        \\local R = {{ frames = {d}, pose = {d}, unhandled = {d}, countdown = {d}, cell = {d}, map = {d},
        \\  samx = {d}, samy = {d}, camx = {d}, camy = {d}, health = {d}, dispHealth = {d}, tanks = {d},
        \\  maxMiss = {d}, curMiss = {d}, items = {d}, beam = {d}, weapon = {d}, facing = {d},
        \\  metReal = {d}, metDisp = {d}, loading = {d}, mode = {d}, contact = {d}, cooldown = {d},
        \\  due = {d}, colTab = {d}, solid = {d}, tilemap = {d}, downSpeed = {d} }}
        \\
    , .{
        try sym("VarFrameCount"),  try sym("VarPose"),          try sym("VarUnhandled"),
        try sym("VarCountdown"),   try sym("VarCell"),          try sym("VarMapIndex"),
        try sym("VarSamusX"),      try sym("VarSamusY"),        try sym("VarCamX"),
        try sym("VarCamY"),        try sym("VarHealthLo"),      try sym("VarDispHealthLo"),
        try sym("VarTanks"),       try sym("VarMaxMissLo"),     try sym("VarCurMissLo"),
        try sym("VarItems"),       try sym("VarBeam"),          try sym("VarActiveWeapon"),
        try sym("VarFacing"),      try sym("VarMetReal"),       try sym("VarMetDisp"),
        try sym("VarLoadingFromFile"), try sym("VarDeathMode"), try sym("VarSaveContact"),
        try sym("VarSaveCooldown"), try sym("VarSaveDue"),      try sym("VarColTab"),
        try sym("VarSolid"),       screen.ram.tilemap_buf,      screen.ram.down_speed,
    });

    try w.print(
        \\local POSE_START, COUNTDOWN, POSE_STAND = {d}, {d}, {d}
        \\local BLOCK_SAVE = {d}
        \\local BOTTOM, LEFT = {d}, {d}
        \\-- One Alpha down, which is what the recording's own first save carries
        \\-- (`save.recorded_save`) and what a kill in the region reaches. It is
        \\-- *written*, not played: killing one is Step 13d's phases and this rung
        \\-- boots from the title. NEW_GAME is the cartridge's own starting count,
        \\-- so "not a new game's" below is the ROM's number.
        \\local AFTER_KILL, MET_DISP, NEW_GAME = {d}, {d}, {d}
        \\local ONE_UNIT = {d}
        \\local ENERGY_AT = {d}
        \\local PERTURB = {s}
        \\local SLOTN = {d}
        \\-- The slot the trip saves in, its record's and spawn flags' offsets in
        \\-- cartridge RAM (`$A000 + slot*$40`, `$1000 + slot*$200`), the
        \\-- window's length, `saveLastSlot`, and where the buffer is in WRAM.
        \\local SLOT, BASE, SPAWN, SPAWN_LEN, LAST_SLOT = {d}, {d}, {d}, {d}, {d}
        \\local SPAWN_BUF, ACTIVE_SLOT = {d}, {d}
        \\-- The table with a station in it, and the tile the rung lays. The
        \\-- address is where `FindBlob` put that blob; the engine stores the same
        \\-- number into `!ColTab` when a door names the tileset.
        \\local STATION_TAB, STATION_TILE = {d}, {d}
        \\
    , .{
        boot.pose, boot.countdown, screen.pose.stand,
        try sym("ConstBlockSave"),
        @as(u16, physics.oam_y_ofs) + @as(u16, @intCast(physics.origin_y_to_bottom)),
        @as(u16, physics.oam_x_ofs) + @as(u16, @intCast(physics.origin_x_to_left)) + 1,
        @as(u8, 0x46), @as(u8, 0x38), new_game.metroid_count_real,
        @as(u8, 0x01),
        energyOffset(),
        if (run == .energy_fault) "true" else "false",
        save.record_len,
        run.slot(),
        @as(u32, run.slot()) * save.slot_size,
        @as(u32, 0x1000) + @as(u32, run.slot()) * 0x200,
        @as(u32, try engineDefine("!SPAWN_WINDOW = $")) * try engineDefine("!SPAWN_BANKS  = "),
        title_oracle.last_slot_offset,
        try engineDefine("!SpawnSaveBuf = $7E"), try sym("VarActiveSlot"),
        station.addr, station.tile,
    });
    // Where each field sits in the slot, from `save.fields` by the Game Boy
    // address the ROM's own writer reads it from.
    try w.print(
        \\-- Slot offsets, generated from `save.fields`.
        \\local O = {{ samy = {d}, samx = {d}, camy = {d}, camx = {d}, bank = {d},
        \\  items = {d}, beam = {d}, tanks = {d}, health = {d}, maxMiss = {d},
        \\  curMiss = {d}, facing = {d}, metReal = {d}, metDisp = {d} }}
        \\
    , .{
        recOffset(0xFFC0), recOffset(0xFFC2), recOffset(0xFFC8), recOffset(0xFFCA),
        recOffset(0xD811), recOffset(0xD045), recOffset(0xD055), recOffset(0xD050),
        recOffset(0xD051), recOffset(0xD081), recOffset(0xD053), recOffset(0xD02B),
        recOffset(0xD089), recOffset(0xD09A),
    });
    try writeBytes(w, "TITLE_IDS", title_ids);

    try w.print(
        \\
        \\local frames, phase, since, hold = 0, 0, 0, nil
        \\local sv, WANT = {{}}, nil
        \\
        \\local function titleUp()
        \\  for i = 1, #TITLE_IDS do
        \\    if (rd16(0x1000 + (i - 1) * 2, vram) & 0x3FF) ~= ((TITLE_IDS[i] + 0x80) & 0xFF) then return false end
        \\  end
        \\  return true
        \\end
        \\
        \\-- The station, laid the way phase 26 lays it: the tile ids come out of
        \\-- the collision table the cart loaded, so the floor under her is a
        \\-- station by the engine's own reckoning and not by this script's.
        \\local function pointAtStationTable()
        \\  emu.write(R.colTab, STATION_TAB & 0xFF, wram)
        \\  emu.write(R.colTab + 1, (STATION_TAB >> 8) & 0xFF, wram)
        \\  emu.write(R.colTab + 2, (STATION_TAB >> 16) & 0xFF, wram)
        \\end
        \\
        \\local function layStation()
        \\  local solid = emu.read(R.solid, wram)
        \\  local ptr = rd16(R.colTab, wram) | (emu.read(R.colTab + 2, wram) << 16)
        \\  local function byte(id) return emu.read(ptr + id, emu.memType.snesMemory) end
        \\  local save_id, air
        \\  for id = solid - 1, 4, -1 do
        \\    if save_id == nil and byte(id) == BLOCK_SAVE then save_id = id end
        \\  end
        \\  for id = solid, 0xFF do if air == nil and byte(id) == 0 then air = id end end
        \\  if save_id == nil or air == nil then return nil end
        \\  local samy, samx = rd16(R.samy, wram), rd16(R.samx, wram)
        \\  local fr = (((samy & 0xFF) + BOTTOM - 16) & 0xF8) // 8
        \\  local fc = (((samx & 0xFF) + LEFT - 8) & 0xF8) // 8
        \\  for r = fr - 6, fr + 1 do
        \\    for c = fc - 3, fc + 4 do
        \\      local o = ((r % 32) * 32 + (c % 32)) * 2
        \\      emu.write(R.tilemap + o, r < fr and air or save_id, wram)
        \\    end
        \\  end
        \\  return save_id
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  if frames < 40 then return end
        \\  if rd16(0, cgram) == 0x7C1F then emu.stop(200) end
        \\  if emu.read(R.unhandled, wram) ~= 0 then emu.stop(210) end
        \\  since = since + 1
        \\  local pose = emu.read(R.pose, wram)
        \\
        \\  if phase == 0 then
        \\    -- A blank cart, and a new game: nothing is handed to this one.
        \\    if rd16(R.frames, wram) < 5 or not titleUp() then
        \\      if since > 300 then emu.stop(201) end
        \\      return
        \\    end
        \\    for i = 0, 0x1FFF do emu.write(i, 0, sram) end
        \\    if SLOT == 0 then
        \\      hold, phase, since = "start", 1, 0
        \\    else
        \\      hold, phase, since = "left", 0.5, 0
        \\    end
        \\    return
        \\  end
        \\
        \\  if phase == 0.5 then
        \\    -- One Left, from the slot 0 a zeroed cart opens on, wraps to 2.
        \\    if since == 3 then hold = nil end
        \\    if since < 8 then return end
        \\    if emu.read(ACTIVE_SLOT, wram) ~= SLOT then emu.stop(213) end
        \\    hold, phase, since = "start", 1, 0
        \\    return
        \\  end
        \\
        \\  if phase == 1 then
        \\    if since == 4 then hold = nil end
        \\    if pose ~= POSE_START then
        \\      if since > 600 then emu.stop(201) end
        \\      return
        \\    end
        \\    if rd16(R.countdown, wram) ~= 0 then return end
        \\    -- **A new game hands over on a button, not on the countdown.** It is
        \\    -- a *load* that hands over with nothing held (`loadingFromFile`,
        \\    -- 00:$0EBD), which is what Step 15b's code 170 grades; here she has
        \\    -- to be asked. The death rung presses the same direction for the
        \\    -- same reason.
        \\    hold, phase, since = "right", 2, 0
        \\    return
        \\  end
        \\
        \\  if phase == 2 then
        \\    -- Control, which is the pose machine taking her off the appearance
        \\    -- pose. Phase 26 sets up from here and not from the countdown.
        \\    if pose == POSE_START then
        \\      if since > 120 then emu.stop(201) end
        \\      return
        \\    end
        \\    hold = nil
        \\    -- The loadout the record has to carry: one unit of energy, and a
        \\    -- Metroid count that is not a new game's. Morph is cleared and she
        \\    -- is stood up, as phase 26 does, so the bottom probe is the one the
        \\    -- station is read by.
        \\    emu.write(R.health, ONE_UNIT, wram); emu.write(R.health + 1, 0, wram)
        \\    emu.write(R.dispHealth, ONE_UNIT, wram); emu.write(R.dispHealth + 1, 0, wram)
        \\    emu.write(R.metReal, AFTER_KILL, wram)
        \\    emu.write(R.metDisp, MET_DISP, wram)
        \\    emu.write(R.items, 0, wram)
        \\    emu.write(R.pose, POSE_STAND, wram)
        \\    emu.write(R.downSpeed, 0, wram)
        \\    pointAtStationTable()
        \\    sv.py, sv.rest = rd16(R.samy, wram), 0
        \\    phase, since = 3, 0
        \\    return
        \\  end
        \\
        \\  if phase == 3 then
        \\    -- The station under her, re-laid each frame because the streamer
        \\    -- draws over the buffer as she settles, and held until she has been
        \\    -- still on it for eight frames -- the same rest phase 26 waits for,
        \\    -- and for the same reason: the contact is set by the collision's
        \\    -- bottom probe, which wants her on the floor.
        \\    local samy = rd16(R.samy, wram)
        \\    pointAtStationTable()
        \\    if layStation() == nil then emu.stop(212) end
        \\    if pose == POSE_STAND and samy == sv.py then sv.rest = sv.rest + 1 else sv.rest = 0 end
        \\    sv.py = samy
        \\    if since > 300 then emu.stop(202) end
        \\    if sv.rest < 8 then return end
        \\    if emu.read(R.contact, wram) ~= 0xFF then emu.stop(202) end
        \\    if emu.read(R.cooldown, wram) ~= 0 then return end
        \\    hold, phase, since = "start", 4, 0
        \\    return
        \\  end
        \\
        \\  if phase == 4 then
        \\    if since == 1 then hold = nil end
        \\    -- The writer runs the frame after Start's edge, as on the Game Boy.
        \\    if emu.read(BASE, sram) == 0 then
        \\      if since > 12 then emu.stop(203) end
        \\      return
        \\    end
        \\    -- **The record the cart wrote, captured from cartridge RAM.** This
        \\    -- is what the load is graded against: not a record the gate chose,
        \\    -- and not the live variables, which the reboot is about to clear.
        \\    WANT = {{}}
        \\    for i = 1, SLOTN do WANT[i] = emu.read(BASE + i - 1, sram) end
        \\    -- Step 24i. Only the slot's record and window were written, the
        \\    -- window is the buffer, and Start named the slot.
        \\    for s = 0, 2 do
        \\      if s ~= SLOT then
        \\        for i = 0, 0x3F do
        \\          if emu.read(s * 0x40 + i, sram) ~= 0 then emu.stop(214) end
        \\        end
        \\        for i = 0, SPAWN_LEN - 1 do
        \\          if emu.read(0x1000 + s * 0x200 + i, sram) ~= 0 then emu.stop(214) end
        \\        end
        \\      end
        \\    end
        \\    for i = 0, SPAWN_LEN - 1 do
        \\      if emu.read(SPAWN + i, sram) ~= emu.read(SPAWN_BUF + i, wram) then emu.stop(214) end
        \\    end
        \\    if emu.read(LAST_SLOT, sram) ~= SLOT then emu.stop(214) end
        \\    if PERTURB then
        \\      local was = emu.read(BASE + ENERGY_AT, sram)
        \\      emu.write(BASE + ENERGY_AT, (was + 1) & 0xFF, sram)
        \\    end
        \\    -- And the death: zero displayed health, the lever Step 15c graded.
        \\    for i = 0, 1 do
        \\      emu.write(R.health + i, 0, wram)
        \\      emu.write(R.dispHealth + i, 0, wram)
        \\    end
        \\    phase, since = 5, 0
        \\    return
        \\  end
        \\
        \\  if phase == 5 then
        \\    -- Through the death to the title. The lengths are Step 15c's rung's
        \\    -- business; what this one needs is that it arrives, and that the
        \\    -- record it wrote is still in cartridge RAM when it does.
        \\    if not titleUp() or rd16(R.frames, wram) >= 5 and emu.read(R.mode, wram) ~= 0 then
        \\      if since > 900 then emu.stop(204) end
        \\      return
        \\    end
        \\    for i = 1, SLOTN do
        \\      local want = WANT[i]
        \\      if PERTURB and i - 1 == ENERGY_AT then want = (want + 1) & 0xFF end
        \\      if emu.read(BASE + i - 1, sram) ~= want then emu.stop(204) end
        \\    end
        \\    -- The reboot took the slot from `saveLastSlot`, as `bootRoutine` does.
        \\    if emu.read(ACTIVE_SLOT, wram) ~= SLOT then emu.stop(215) end
        \\    hold, phase, since = "start", 6, 0
        \\    return
        \\  end
        \\
        \\  if phase == 6 then
        \\    if since == 4 then hold = nil end
        \\    local cd = rd16(R.countdown, wram)
        \\    if pose ~= POSE_START or cd == 0 or cd >= COUNTDOWN then
        \\      if since > 300 then emu.stop(205) end
        \\      return
        \\    end
        \\    -- It loaded, rather than starting a new game.
        \\    if emu.read(R.loading, wram) ~= 0xFF then emu.stop(205) end
        \\    -- And the spawn flags came from the slot's window (Step 24i).
        \\    for i = 0, SPAWN_LEN - 1 do
        \\      if emu.read(SPAWN_BUF + i, wram) ~= emu.read(SPAWN + i, sram) then emu.stop(215) end
        \\    end
        \\
        \\    -- **The record, field by field, against the bytes the cart wrote.**
        \\    -- `save.fields` says which record offset each live variable goes to,
        \\    -- and the offsets below are generated from it, so a field that moves
        \\    -- in the writer moves here too.
        \\    local function slot(i) return WANT[i + 1] end
        \\    local function slot16(i) return slot(i) | (slot(i + 1) << 8) end
        \\    local WANT_MAP = slot(O.bank) - 9
        \\    local WANT_CELL = (slot(O.samy + 1) << 4) | slot(O.samx + 1)
        \\
        \\    if emu.read(R.map, wram) ~= WANT_MAP or emu.read(R.cell, wram) ~= WANT_CELL then emu.stop(206) end
        \\    if rd16(R.samy, wram) ~= slot16(O.samy) then emu.stop(206) end
        \\    if rd16(R.samx, wram) ~= slot16(O.samx) then emu.stop(206) end
        \\    if rd16(R.camy, wram) ~= slot16(O.camy) then emu.stop(206) end
        \\    if rd16(R.camx, wram) ~= slot16(O.camx) then emu.stop(206) end
        \\
        \\    -- **The energy is the point of the scenario.** She saved holding one
        \\    -- unit and died holding none; the number that comes back has to be
        \\    -- the record's. The `energy_fault` run changes exactly this byte in
        \\    -- the slot after the record is captured, so this is the line it
        \\    -- fails on.
        \\    if rd16(R.health, wram) ~= slot16(O.health) then emu.stop(207) end
        \\    if rd16(R.dispHealth, wram) ~= slot16(O.health) then emu.stop(207) end
        \\    if emu.read(R.tanks, wram) ~= slot(O.tanks) then emu.stop(207) end
        \\    if rd16(R.maxMiss, wram) ~= slot16(O.maxMiss) then emu.stop(207) end
        \\    if rd16(R.curMiss, wram) ~= slot16(O.curMiss) then emu.stop(207) end
        \\
        \\    -- **`metroidCountReal` persists.** The record was written after a
        \\    -- kill, so what comes back is that count and not the number the
        \\    -- cartridge starts a new game with. Both halves are checked: equal
        \\    -- to the record, and not equal to a new game's.
        \\    if emu.read(R.metReal, wram) ~= slot(O.metReal) then emu.stop(208) end
        \\    if emu.read(R.metDisp, wram) ~= slot(O.metDisp) then emu.stop(208) end
        \\    if emu.read(R.metReal, wram) ~= AFTER_KILL then emu.stop(208) end
        \\    if emu.read(R.metReal, wram) == NEW_GAME then emu.stop(208) end
        \\
        \\    if emu.read(R.items, wram) ~= slot(O.items) then emu.stop(209) end
        \\    if emu.read(R.beam, wram) ~= slot(O.beam) then emu.stop(209) end
        \\    if emu.read(R.facing, wram) ~= slot(O.facing) then emu.stop(209) end
        \\
        \\    phase, since = 7, 0
        \\    return
        \\  end
        \\
        \\  -- And control arrives, with nothing held: the same handover Step 15b
        \\  -- grades, reached this time from a record the cart wrote itself.
        \\  if pose == POSE_START then
        \\    if since > 400 then emu.stop(211) end
        \\    return
        \\  end
        \\  emu.stop(0)
        \\end, emu.eventType.endFrame)
        \\
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput({{ [hold] = true }}, 0) end
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

/// A record offset by the Game Boy address the writer reads it from.
///
/// Generated from `save.fields` rather than written down, so a field that moves
/// in the ROM's writer moves in the generated script too. The whole point of
/// the round trip is that the record is the cartridge's layout and not ours.
fn recOffset(comptime src: u16) u8 {
    return comptime blk: {
        for (save.fields) |f| {
            if (f.src == src) break :blk f.offset;
        }
        @compileError("no save-record field read from that address");
    };
}

/// The slot offset of the energy byte, which the fault run perturbs. Includes
/// the magic, because it indexes cartridge RAM rather than the record.
fn energyOffset() u8 {
    return comptime blk: {
        for (save.fields) |f| {
            if (std.mem.eql(u8, f.name, "energy")) break :blk f.offset;
        }
        @compileError("no save-record field named energy");
    };
}

/// A byte table, sixteen to a line so the generated file stays readable.
/// The title's file select, Step 24h (B14): the shipped cart's title, driven
/// through `title_oracle.script` and graded against the Game Boy running the
/// same script from the same cold boot.
pub const TitleRun = enum {
    /// The Game Boy's record: the cart must match it.
    grade,
    /// The same record with the cursor's frames shifted one step: the rung
    /// must fail, on code 96, or it is not comparing sprites.
    phase_fault,
    /// Step 24i. `saveLastSlot` out of range, 3: the title must open on slot
    /// 0, as `bootRoutine`'s `CP $03` leaves it. Graded for the title's first
    /// frames only; the graded run covers the rest.
    last_slot_3,

    fn lastSlot(r: TitleRun) u8 {
        return switch (r) {
            .grade, .phase_fault => title_oracle.seed_last_slot,
            .last_slot_3 => 3,
        };
    }

    /// The title frame the run stops on, passing; null for the whole script.
    fn stopAt(r: TitleRun) ?u16 {
        return switch (r) {
            .grade, .phase_fault => null,
            .last_slot_3 => 4,
        };
    }
};

/// Cartridge RAM as the script finds it before the cart runs a cycle: all
/// zero but `seed` from byte 0. Mesen keeps a cart's RAM between runs under
/// its file name and powers a fresh one on with noise, and since Step 24i the
/// title's slot is read from it at boot (`saveLastSlot`, $A0C0), so a rung that
/// boots the title says what it holds. Lua's main chunk runs before the first
/// instruction (measured 2026-09-25: a write here is what the cart reads).
pub fn writeSramPrelude(w: *std.Io.Writer, seed: []const u8) !void {
    try w.print(
        \\-- Cartridge RAM before the boot: zero, and the seed (Step 24i).
        \\for i = 0, 0x1FFF do emu.write(i, 0, emu.memType.snesSaveRam) end
        \\
    , .{});
    if (seed.len == 0) return;
    try writeBytes(w, "SRAM_SEED", seed);
    try w.print(
        \\for i = 1, #SRAM_SEED do emu.write(i - 1, SRAM_SEED[i], emu.memType.snesSaveRam) end
        \\
    , .{});
}

/// A Game Boy OAM entry as the cart's `PutObject` writes it: x and y moved
/// into the play window, the flips a bit left, OBP1 as palette 1, and the
/// behind-background bit as priority 0 against 2. One number, so a frame's set
/// sorts and compares as a string.
fn titleObjKey(o: title_oracle.Obj) u64 {
    const x: u64 = (@as(u64, o.x) + screen.win_left - physics.oam_x_ofs) & 0x1FF;
    const y: u64 = (@as(u64, o.y) + screen.band_top - physics.oam_y_ofs) & 0xFF;
    var attr: u64 = (@as(u64, o.attr) & 0x60) << 1;
    if (o.attr & 0x10 != 0) attr |= 0x02;
    if (o.attr & 0x80 == 0) attr |= 0x20;
    return (x << 24) | (y << 16) | (@as(u64, o.tile) << 8) | attr;
}

fn writeTitleSprites(w: *std.Io.Writer, objs: []const title_oracle.Obj) !void {
    var keys: [title_oracle.max_objs]u64 = undefined;
    for (objs, 0..) |o, i| keys[i] = titleObjKey(o);
    std.mem.sort(u64, keys[0..objs.len], {}, std.sort.asc(u64));
    try w.print("\"", .{});
    for (keys[0..objs.len]) |k| try w.print("{d},", .{k});
    try w.print("\"", .{});
}

pub fn writeTitle(gpa: std.mem.Allocator, rom: []const u8, boot: screen.Boot, mode: TitleRun, w: *std.Io.Writer) !void {
    const seed = title_oracle.seedSlots(mode.lastSlot());
    var run = try title_oracle.run(gpa, rom, &title_oracle.script, &seed);
    defer run.deinit(gpa);
    const menu = try title_oracle.Menu.read(rom);
    const frames = run.frames;
    // The last frame is the one the Game Boy left the title on.
    const left = frames.len - 1;
    if (frames[left].mode == title_oracle.mode_title or frames[left].loading != 0) return error.TitleNeverStarted;
    const stop_at: u16 = mode.stopAt() orelse 0;

    const rows = try title_oracle.renderRows(gpa, rom, 4);
    // Step 24j: the same frame, whole, with "Super" laid over it as classes 4
    // (red) and 5 (blue), cut to the rectangle the rung grades.
    var title = try title_oracle.renderTitle(gpa, rom, 4);
    try title_super.composite(gpa, &title, 160, 4);
    const sr = title_super.rect;
    var super_px: [(sr.y1 - sr.y0) * (sr.x1 - sr.x0)]u8 = undefined;
    for (sr.y0..sr.y1) |y| @memcpy(super_px[(y - sr.y0) * (sr.x1 - sr.x0) ..][0 .. sr.x1 - sr.x0], title[y * 160 + sr.x0 ..][0 .. sr.x1 - sr.x0]);
    const super_red = title_super.bgr15(title_super.red);
    const super_blue = title_super.bgr15(title_super.blue);
    const run_at = offsets.find(inject.title_sheets[0]) orelse return error.MissingTitleSheet;
    const obj_chr = try @import("snes_chr.zig").to4bpp(gpa, rom[run_at.romOffset()..][0 .. 0x80 * 16]);
    defer gpa.free(obj_chr);

    const sym = struct {
        fn f(name: []const u8) !u32 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.f;

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The title's file select, Step 24h ({s}): the shipped cart's title
        \\-- driven through `title_oracle.script` and graded, frame for frame,
        \\-- against our Game Boy running the same script from a cold boot.
        \\--
        \\-- **One clock on both machines.** Each runs a vblank (the counter up,
        \\-- the shadow out) and then one `titleScreenRoutine`: draw, then pad. So
        \\-- title frame n is the iteration run with the counter at n, on the cart
        \\-- `!FrameCount` and on the Game Boy `frameCounter`, and the cursor's
        \\-- phase is graded with no offset to tune. Two measured facts place the
        \\-- samples (Step 24h, 2026-09-25). Mesen's end of frame falls after the
        \\-- iteration and before the next upload, so the cart's *shadow* is frame
        \\-- n's draw and its OAM frame n-1's. And the cart polls a vblank earlier
        \\-- than it consumes (`PublishPad`), where the Game Boy polls in the
        \\-- vblank before, so the pad the Game Boy holds for frame t is set on
        \\-- the cart's poll at vblank t.
        \\--
        \\-- Exit codes:
        \\--   0  the title did what the Game Boy's did
        \\--  90  Fatal ran
        \\--  91  the title never came up
        \\--  92  the title did not open as the Game Boy's: the option hidden, clear
        \\--      unselected, and the slot `saveLastSlot` names, or 0 (Step 24i)
        \\--  93  rows 16 and 17 are not the Game Boy's pixels: the copyright row
        \\--  94  the title's object characters are not the cartridge's first sheet
        \\--  95  a state byte (the option, clear selected, the slot) is not the Game Boy's on some frame
        \\--  96  the menu's sprites are not the Game Boy's on some frame
        \\--  97  the clear or Start left the slots or `saveLastSlot` other than the Game Boy's
        \\--  98  Start after the clear did not start a new game
        \\--  99  the cart left the title on another frame than the Game Boy's
        \\-- 100  the engine was handed a pose it could not run
        \\-- 101  "Super" is not `super.png` at `super_at` over the Game Boy's title,
        \\--      or its two colours are not the approved ones in CGRAM (Step 24j)
        \\-- 102  "Super" is still in BG1's map once the game has started
        \\-- 103  a frame asked for the select sound another number of times than
        \\--      the Game Boy's (Step 24i): the cart's `!AudRec` against the
        \\--      stores `title_oracle.selectSites` finds, executed
        \\--
        \\-- On a failure, SRAM $1F00-$1F01 holds the title frame it was found on.
        \\-- Codes 95 and 96 before the first press are the cursor's phase or the
        \\-- menu's shape; from a press on, the press's timing.
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local sram  = emu.memType.snesSaveRam
        \\local cgram = emu.memType.snesCgRam
        \\local oam   = emu.memType.snesSpriteRam
        \\local function rd16(addr, kind) return emu.read(addr, kind) | (emu.read(addr + 1, kind) << 8) end
        \\
        \\local R = {{ frames = {d}, unhandled = {d}, show = {d}, sel = {d}, slot = {d}, loading = {d},
        \\  pose = {d}, countdown = {d}, cell = {d}, map = {d} }}
        \\local POSE_START, COUNTDOWN, NEW_CELL, NEW_MAP = {d}, {d}, {d}, {d}
        \\local HIDDEN_Y = {d}
        \\local WIN_LEFT, BAND_TOP, VIEW_W = {d}, {d}, {d}
        \\local OVERSCAN = (239 - 224) // 2
        \\local ROWS_FIRST, ROWS_LEN = {d}, {d}
        \\local OBJ_VRAM, OAM_BUF = {d}, {d}
        \\-- The frame the Game Boy's Start was taken on. The cart leaves inside
        \\-- that frame's iteration -- NMI off, and `InitState` reseeds the
        \\-- counter from the boot record before the frame ends -- so the last
        \\-- title frame it shows is LEFT - 1: a Start taken a frame early shows
        \\-- LEFT - 2, and one a frame late shows LEFT.
        \\local LEFT = {d}
        \\-- Step 24i: this tick's sound record, and the pair the select sound is.
        \\local AUD_REC_LEN, AUD_REC, REQ_SQ1, SFX_SELECT = {d}, {d}, {d}, {d}
        \\local STOP_AT = {d}
        \\
    , .{
        @tagName(mode),
        try sym("VarFrameCount"),   try sym("VarUnhandled"),     try sym("VarTitleShowClear"),
        try sym("VarTitleClearSel"), try sym("VarActiveSlot"),   try sym("VarLoadingFromFile"),
        try sym("VarPose"),         try sym("VarCountdown"),     try sym("VarCell"),
        try sym("VarMapIndex"),
        boot.pose,                  boot.countdown,              boot.cell,
        boot.map_index,
        try engineDefine("!OAM_HIDDEN_Y = $"),
        screen.win_left,            screen.band_top,             target.view_w,
        title_oracle.rows_first,    title_oracle.rows_len,
        (@as(u32, 0x6000) + 0x80 * 16) * 2, try sym("VarOamBuf"),
        left,
        try engineDefine("!AudRecLen    = $"), try engineDefine("!AudRec       = $"),
        try engineDefine("!REQ_SFX_SQUARE1 = "), try engineDefine("!SFX_SELECT   = $"),
        stop_at,
    });
    try w.print(
        \\-- Step 24j: "Super"'s rectangle in Game Boy pixels, its two colours'
        \\-- CGRAM words (BG palette 7, entries 1 and 2), and its patch in BG1's map.
        \\local SUPER_X0, SUPER_Y0, SUPER_W, SUPER_H = {d}, {d}, {d}, {d}
        \\local SUPER_CG, SUPER_RED, SUPER_BLUE = {d}, {d}, {d}
        \\local SUPER_MAP, SUPER_COLS, SUPER_ROWS = {d}, {d}, {d}
        \\
        \\
    , .{
        sr.x0,                      sr.y0,                       sr.x1 - sr.x0,
        sr.y1 - sr.y0,
        (@as(u32, title_super.palette) * 16 + 1) * 2, super_red,  super_blue,
        (try sym("ConstReadoutMap") + title_super.patch.map_offset) * 2,
        title_super.patch.cols,     title_super.patch.rows,
    });

    // Per title frame: the three state bytes and the menu's sprites, as the
    // cart's OAM would hold them, and the pad the Game Boy was given.
    try w.print("ST = {{\n", .{});
    for (frames[0 .. left + 1]) |f| try w.print("  {{ {d}, {d}, {d} }},\n", .{ f.show_clear, f.clear_selected, f.slot });
    try w.print("}}\nSFXN = {{", .{});
    for (frames[0 .. left + 1]) |f| try w.print(" {d},", .{f.sfx});
    try w.print(" }}\nSP = {{\n", .{});
    for (frames[0 .. left + 1], 0..) |f, t| {
        try w.print("  ", .{});
        switch (mode) {
            .grade, .last_slot_3 => try writeTitleSprites(w, f.sprites()),
            .phase_fault => {
                // The same frame as the ROM draws it four counts later: the
                // cursor one step on, everything else unchanged.
                if (t == 0) {
                    try writeTitleSprites(w, f.sprites());
                } else {
                    const s = frames[t - 1];
                    const g = try title_oracle.menuFor(rom, menu, s.fc +% 4, s.slot, s.clear_selected, s.show_clear);
                    try writeTitleSprites(w, g.sprites());
                }
            },
        }
        try w.print(",\n", .{});
    }
    try w.print("}}\nPAD = {{\n", .{});
    for (frames[0 .. left + 1]) |f| {
        try w.print("  {{", .{});
        const names = [_][]const u8{ "b", "y", "select", "start", "right", "left", "up", "down" };
        for (names, 0..) |n, bit| if (f.pad & (@as(u8, 1) << @intCast(bit)) != 0) try w.print(" {s} = true,", .{n});
        try w.print(" }},\n", .{});
    }
    try w.print("}}\n", .{});
    try writeBytes(w, "ROWS", &rows);
    try writeBytes(w, "SUPER", &super_px);
    try writeBytes(w, "OBJCHR", obj_chr);
    try writeBytes(w, "AFTER", &run.slots_after);
    try writeSramPrelude(w, &seed);

    try w.print(
        \\
        \\local frames, phase, prevT, since = 0, 0, 0, 0
        \\
        \\local function fail(code, t)
        \\  emu.write(0x1F00, t & 0xFF, sram)
        \\  emu.write(0x1F01, (t >> 8) & 0xFF, sram)
        \\  emu.stop(code)
        \\end
        \\
        \\-- The PPU's OAM or the shadow in WRAM, which has OAM's layout.
        \\local function sprites(base, kind)
        \\  local keys = {{}}
        \\  for i = 0, 127 do
        \\    local y = emu.read(base + i * 4 + 1, kind)
        \\    if y ~= HIDDEN_Y then
        \\      local hi = (emu.read(base + 512 + (i >> 2), kind) >> ((i & 3) * 2)) & 1
        \\      local x = emu.read(base + i * 4, kind) | (hi << 8)
        \\      keys[#keys + 1] = (x << 24) | (y << 16) | (emu.read(base + i * 4 + 2, kind) << 8) | emu.read(base + i * 4 + 3, kind)
        \\    end
        \\  end
        \\  table.sort(keys)
        \\  local s = ""
        \\  for _, k in ipairs(keys) do s = s .. k .. "," end
        \\  return s
        \\end
        \\
        \\local function shade(px)
        \\  local r = (px >> 16) & 0xFF
        \\  if r > 200 then return 0 elseif r > 120 then return 1
        \\  elseif r > 40 then return 2 else return 3 end
        \\end
        \\
        \\-- A 15-bit colour as Mesen draws it: each channel c becomes (c << 3) | (c >> 2).
        \\local function rgb(c)
        \\  local function x(v) return (v << 3) | (v >> 2) end
        \\  return (x(c & 31) << 16) | (x((c >> 5) & 31) << 8) | x((c >> 10) & 31)
        \\end
        \\local RED_RGB, BLUE_RGB = rgb(SUPER_RED), rgb(SUPER_BLUE)
        \\
        \\-- "Super"'s two colours as classes 4 and 5; everything else a shade.
        \\local function class(px)
        \\  local c = px & 0xFFFFFF
        \\  if c == RED_RGB then return 4 elseif c == BLUE_RGB then return 5 end
        \\  return shade(px)
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(90, prevT) end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(100, prevT) end
        \\  local t = rd16(R.frames, wram)
        \\
        \\  if phase == 0 then
        \\    -- Boot runs with NMI off, the ARAM upload with it, and the counter
        \\    -- does not move until the title turns NMI on.
        \\    if t == 0 then
        \\      if frames > 600 then fail(91, 0) end
        \\      return
        \\    end
        \\    -- The first title frame this script sees. Cartridge RAM was
        \\    -- seeded before the boot, as the Game Boy's was (the prelude).
        \\    for i = 1, #OBJCHR do
        \\      if emu.read(OBJ_VRAM + i - 1, vram) ~= OBJCHR[i] then fail(94, t) end
        \\    end
        \\    phase = 1
        \\  end
        \\
        \\  if phase == 1 then
        \\    if prevT > 0 and t ~= prevT + 1 then
        \\      -- The counter stopped: Start turned NMI off. The Game Boy left
        \\      -- on title frame LEFT, and the cart must have too.
        \\      if prevT ~= LEFT - 1 then fail(99, prevT) end
        \\      for i = 1, #AFTER do
        \\        if emu.read(i - 1, sram) ~= AFTER[i] then fail(97, prevT) end
        \\      end
        \\      phase, since = 2, 0
        \\      return
        \\    end
        \\    if t >= LEFT then fail(99, t) end
        \\    prevT = t
        \\    local st = ST[t + 1]
        \\    local show, sel, slot = emu.read(R.show, wram), emu.read(R.sel, wram), emu.read(R.slot, wram)
        \\    if t == 1 and (show ~= 0 or sel ~= 0 or slot ~= ST[1][3]) then fail(92, t) end
        \\    if show ~= st[1] or sel ~= st[2] or slot ~= st[3] then fail(95, t) end
        \\    -- The select sound, as many times as the Game Boy asked for it.
        \\    local n = 0
        \\    for i = 0, rd16(AUD_REC_LEN, wram) - 2, 2 do
        \\      if emu.read(AUD_REC + i, wram) == REQ_SQ1 and emu.read(AUD_REC + i + 1, wram) == SFX_SELECT then n = n + 1 end
        \\    end
        \\    if n ~= SFXN[t + 1] then fail(103, t) end
        \\    if sprites(OAM_BUF, wram) ~= SP[t + 1] then fail(96, t) end
        \\    if t > 1 and sprites(0, oam) ~= SP[t] then fail(96, t) end
        \\    if t == 5 then
        \\      local buf = emu.getScreenBuffer()
        \\      for y = 0, ROWS_LEN - 1 do
        \\        for x = 0, VIEW_W - 1 do
        \\          local px = buf[(BAND_TOP + OVERSCAN + ROWS_FIRST + y) * 256 + WIN_LEFT + x + 1]
        \\          if shade(px) ~= ROWS[y * VIEW_W + x + 1] then fail(93, t) end
        \\        end
        \\      end
        \\      -- "Super" (Step 24j). The palette first, from the converter's
        \\      -- words, since a pixel comparison alone would pass a wrong one.
        \\      if rd16(SUPER_CG, cgram) ~= SUPER_RED or rd16(SUPER_CG + 2, cgram) ~= SUPER_BLUE then fail(101, t) end
        \\      for y = 0, SUPER_H - 1 do
        \\        for x = 0, SUPER_W - 1 do
        \\          local px = buf[(BAND_TOP + OVERSCAN + SUPER_Y0 + y) * 256 + WIN_LEFT + SUPER_X0 + x + 1]
        \\          if class(px) ~= SUPER[y * SUPER_W + x + 1] then fail(101, t) end
        \\        end
        \\      end
        \\    end
        \\    if t == STOP_AT then emu.stop(0) end
        \\    return
        \\  end
        \\
        \\  -- Left: a new game, since the clear emptied the slot.
        \\  since = since + 1
        \\  local pose, cd = emu.read(R.pose, wram), rd16(R.countdown, wram)
        \\  if pose ~= POSE_START or cd == 0 or cd >= COUNTDOWN then
        \\    if since > 180 then fail(98, prevT) end
        \\    return
        \\  end
        \\  if emu.read(R.loading, wram) ~= 0 then fail(98, prevT) end
        \\  if emu.read(R.cell, wram) ~= NEW_CELL or emu.read(R.map, wram) ~= NEW_MAP then fail(98, prevT) end
        \\  -- And "Super" left BG1 with the title (Step 24j).
        \\  for r = 0, SUPER_ROWS - 1 do
        \\    for c = 0, SUPER_COLS * 2 - 1 do
        \\      if emu.read(SUPER_MAP + r * 64 + c, vram) ~= 0 then fail(102, prevT) end
        \\    end
        \\  end
        \\  emu.stop(0)
        \\end, emu.eventType.endFrame)
        \\
        \\-- The poll at vblank t, before NMI counts it: the counter still says
        \\-- t - 1, and the pad is the one the Game Boy holds through frame t.
        \\emu.addEventCallback(function()
        \\  if phase ~= 1 then return end
        \\  local p = PAD[rd16(R.frames, wram) + 2]
        \\  if p ~= nil then emu.setInput(p, 0) end
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}

fn writeBytes(w: *std.Io.Writer, name: []const u8, bytes: []const u8) !void {
    try w.print("local {s} = {{\n", .{name});
    for (bytes, 0..) |b, i| {
        if (i % 16 == 0) try w.print(" ", .{});
        try w.print(" {d},", .{b});
        if (i % 16 == 15) try w.print("\n", .{});
    }
    if (bytes.len % 16 != 0) try w.print("\n", .{});
    try w.print("}}\n", .{});
}

// ---- 1.0 Step 2a: the pause ----------------------------------------------------

pub const PauseRun = enum {
    /// The Game Boy's record: the cart must match it.
    grade,
    /// The same record with the flash a frame late: the rung must fail, on
    /// code 114, or it is not comparing the palette.
    flash_fault,
    /// 1.0 Step 2d. The debug menu's chord, L and R held as Start pauses, on
    /// the retail cart: no menu, `debugFlag` clear, and the whole run still the
    /// Game Boy's -- which never had the buttons -- frame for frame.
    combo,
    /// The `--debug` cart from the anchor: the chord opens the menu mid-walk,
    /// A opens SAMUS, B goes back, B closes, she walks on, and the chord opens
    /// and closes it once more.
    debug_combo,

    fn holdsCombo(r: PauseRun) bool {
        return r == .combo;
    }
};

/// The GB pad byte's bits as Mesen's SNES button names: jump (A) is B on the
/// cart and fire (B) is Y, as `!PAD_JUMP` and `!PAD_FIRE` map them.
const pad_names = [_][]const u8{ "b", "y", "select", "start", "right", "left", "up", "down" };

fn writePad(w: *std.Io.Writer, pad: u8) !void {
    try w.print("{{", .{});
    for (pad_names, 0..) |n, bit| if (pad & (@as(u8, 1) << @intCast(bit)) != 0) try w.print(" {s} = true,", .{n});
    try w.print(" }}", .{});
}

pub fn writePause(gpa: std.mem.Allocator, rom: []const u8, mode: PauseRun, w: *std.Io.Writer) !void {
    var run = try pause_oracle.run(gpa, rom, &pause_oracle.script);
    defer run.deinit(gpa);
    const frames = run.frames;

    const sym = struct {
        fn f(name: []const u8) !u32 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.f;

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The pause, 1.0 Step 2a ({s}): the shipped cart started as a new game
        \\-- and driven through `pause_oracle.script`, graded pass for pass against
        \\-- our Game Boy running the same script from a cold boot.
        \\--
        \\-- **The anchor** is the first pass to end in play with the appearance
        \\-- countdown at the Game Boy's value there: `cold boot` grades the
        \\-- countdown frame for frame, so both machines are on the same frame of
        \\-- it. From there frame t is the t-th pass after the anchor, sampled at
        \\-- the top of `MainLoop` on the cart and at `waitForNextFrame` on the
        \\-- Game Boy -- each machine's end of a pass -- and the pad the Game Boy
        \\-- read on iteration t is the one the cart's pass t reads.
        \\--
        \\-- Graded against the Game Boy's own state, not the port's: nothing here
        \\-- reads a variable the port added for the pause, so the same script
        \\-- runs on a cart that has none.
        \\--
        \\-- Exit codes:
        \\--   0  the pause did what the Game Boy's did
        \\-- 110  Fatal ran
        \\-- 111  the title, the new game or the anchor never arrived
        \\-- 112  the engine was handed a pose it could not run
        \\-- 113  a pass after the anchor was not one frame: the counter skipped
        \\-- 114  `bg_palette` is not the Game Boy's on some frame: the flash
        \\-- 115  Samus's position or pose is not the Game Boy's on some frame
        \\-- 116  the in-game timer is not the Game Boy's on some frame
        \\-- 117  the status bar is not the Game Boy's on some frame: the L counter
        \\-- 118  the objects' characters are not the Game Boy's on some frame: the
        \\--      L over the HUD's Metroid
        \\-- 119  a frame asked for the pause or the unpause sound another number of
        \\--      times than the Game Boy's did
        \\-- 120  the frame counter is not the Game Boy's `frameCounter` on some frame
        \\-- 121  `debugFlag` set, or the debug menu up, on a retail cart: nothing
        \\--      sets the flag since 1.0 Step 2d, and the chord is the pause's Start
        \\-- 122  (`debug_combo`) the chord did not open the debug menu with the game
        \\--      frozen behind it: not up, BG1 not alone on every band, its root not
        \\--      "DEBUG", its font's A not the ROM's `gfx_itemFont` tile 0, Samus
        \\--      moved, or the page A opens not "SAMUS"
        \\-- 123  (`debug_combo`) B back, B at the root or the chord again did not
        \\--      close it back to play's layers, or play did not go on
        \\-- 124  (`debug_combo`) the play field's VRAM -- BG3's characters and
        \\--      map, BG1's and the objects' characters -- changed under it
        \\-- 125  the screen's brightness does not follow `bg_palette`: full where
        \\--      the Game Boy's is $93, and dimmer where it is not (1.0 Step 25)
        \\--
        \\-- On a failure, SRAM $1F00-$1F01 holds the frame it was found on.
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local vram  = emu.memType.snesVideoRam
        \\local sram  = emu.memType.snesSaveRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr, kind) return emu.read(addr, kind) | (emu.read(addr + 1, kind) << 8) end
        \\
        \\local R = {{ frames = {d}, unhandled = {d}, countdown = {d}, pose = {d}, x = {d}, y = {d},
        \\  bgp = {d}, igt_s = {d}, igt_m = {d}, igt_h = {d}, oam = {d}, bar = {d},
        \\  rec_len = {d}, rec = {d}, debug = {d} }}
        \\local COMMIT, ANCHOR_CD, REQ_PAUSE = {d}, {d}, {d}
        \\local COMBO, DEBUG_RUN = {s}, {s}
        \\local BANDS, TM_BG1, R_OPEN, R_PAUSED = {d}, {d}, {d}, {d}
        \\local DEBUG_MAP, FONT_A = {d}, {d}
        \\
    , .{
        @tagName(mode),
        try sym("VarFrameCount"),          try sym("VarUnhandled"),          try sym("VarCountdown"),
        try sym("VarPose"),                try sym("VarSamusX"),             try sym("VarSamusY"),
        try engineDefine("!BgPalette    = $"), try engineDefine("!IgtSeconds   = $"), try engineDefine("!IgtMinutes   = $"),
        try engineDefine("!IgtHours     = $"), try sym("VarOamBuf"),         @as(u32, try engineDefine("!BG2_MAP       = $")) * 2,
        try engineDefine("!AudRecLen    = $"), try engineDefine("!AudRec       = $"), try sym("VarDebugFlag"),
        try sym(oracle.commit_symbol),     frames[0].countdown,              try engineDefine("!REQ_PAUSE_CONTROL = "),
        if (mode.holdsCombo()) "true" else "false", if (mode == .debug_combo) "true" else "false",
        try engineDefine("!Bands        = $"), try engineDefine("!TM_BG1       = $"), try sym("VarDebugOpen"),
        try sym("VarPaused"),
        @as(u32, try sym("ConstDebugMapVram")) * 2, (@as(u32, 0x1000) + 0x141 * 16) * 2,
    });
    // The item font's first tile as the debug screen's BG1 must hold it: the
    // ROM's sixteen bytes, planes 0 and 1, and sixteen zeros.
    {
        const e = offsets.find("gfx_itemFont") orelse return error.MissingTable;
        var a: [32]u8 = @splat(0);
        @memcpy(a[0..16], rom[e.romOffset()..][0..16]);
        try writeBytes(w, "FONT_A_BYTES", &a);
    }

    // Per frame: the pad, then the state after it. The objects are graded up
    // to the count the last drawing frame left: the Game Boy's index is zero
    // while paused, and what the pause shows is the buffer that frame left.
    try w.print("PAD = {{\n", .{});
    for (frames) |f| {
        try w.print("  ", .{});
        try writePad(w, f.pad);
        try w.print(",\n", .{});
    }
    try w.print("}}\nST = {{\n", .{});
    var n_objs: usize = 0;
    for (frames, 0..) |f, t| {
        const bgp = switch (mode) {
            .grade => f.bgp,
            .flash_fault => if (t == 0) f.bgp else frames[t - 1].bgp,
            .combo, .debug_combo => f.bgp,
        };
        if (f.oam_index != 0) n_objs = f.oam_index / 4;
        try w.print("  {{ {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, {d}, \"", .{ bgp, f.x, f.y, f.pose, f.igt_s, f.igt_m, f.igt_h, f.pause_req, f.unpause_req });
        for (f.bar) |b| try w.print("{x:0>2}", .{b});
        try w.print("\", \"", .{});
        for (f.tiles[0..n_objs]) |b| try w.print("{x:0>2}", .{b});
        try w.print("\", {d} }},\n", .{f.fc});
    }
    try w.print("}}\n", .{});
    try writeSramPrelude(w, &.{});

    try w.print(
        \\
        \\local phase, t, anchor_fc, starts, frames = 0, nil, nil, 0, 0
        \\
        \\-- `emu.stop` does not return from the callback that calls it, so the
        \\-- checks after a failure still run; only the first one is kept.
        \\local stopped = false
        \\-- INIDISP as last written: the brightness the screen is at. 1.0 Step
        \\-- 25: the flash wrote `bg_palette` and nothing put it on the screen,
        \\-- which 114 could not see.
        \\local SHOWN = nil
        \\emu.addMemoryCallback(function(_, v) SHOWN = v end, emu.callbackType.write, 0x2100, 0x2100, emu.cpuType.snes, emu.memType.snesMemory)
        \\local function fail(code, at, got, want)
        \\  if stopped then return end
        \\  stopped = true
        \\  at = at or 0
        \\  emu.write(0x1F00, at & 0xFF, sram)
        \\  emu.write(0x1F01, (at >> 8) & 0xFF, sram)
        \\  -- What was compared, as text, for whoever reads the save file.
        \\  local function put(base, str)
        \\    str = tostring(str or "")
        \\    for i = 1, math.min(#str, 0xFF) do emu.write(base + i - 1, string.byte(str, i), sram) end
        \\    emu.write(base + math.min(#str, 0xFF), 0, sram)
        \\  end
        \\  put(0x1C00, got)
        \\  put(0x1D00, want)
        \\  emu.stop(code)
        \\end
        \\
        \\local function hex(addr, n, kind, stride)
        \\  local s = ""
        \\  for i = 0, n - 1 do s = s .. string.format("%02x", emu.read(addr + i * stride, kind)) end
        \\  return s
        \\end
        \\
        \\-- The debug cart's run from the anchor (1.0 Step 2c). Its own pad, and
        \\-- its own checks: the Game Boy has no debug screen to be graded against.
        \\local function bandTms()
        \\  return {{ emu.read(BANDS + 1, wram), emu.read(BANDS + 3, wram), emu.read(BANDS + 5, wram),
        \\    emu.read(BANDS + 7, wram), emu.read(BANDS + 9, wram) }}
        \\end
        \\local function vramSum()
        \\  -- BG3's characters and map ($0000-$0BFF words), BG1's characters
        \\  -- below the screen's own ($1000-$23FF) and the objects' ($6000-$7FFF).
        \\  -- Not BG2's map, the status bar, which the pause rewrites.
        \\  local sum = 0
        \\  local function add(first, last)
        \\    for a = first * 2, last * 2 + 1 do sum = (sum * 31 + emu.read(a, vram)) % 2147483647 end
        \\  end
        \\  add(0x0000, 0x0BFF) add(0x1000, 0x23FF) add(0x6000, 0x7FFF)
        \\  return sum
        \\end
        \\local dbg = {{}}
        \\function debugPad(t)
        \\  local p = {{}}
        \\  if (t >= 330 and t < 350) or (t >= 390 and t < 420) then p.right = true end
        \\  if (t >= 345 and t <= 352) or (t >= 425 and t <= 432) or (t >= 440 and t <= 447) then p.l, p.r = true, true end
        \\  if t == 350 or t == 351 or t == 430 or t == 431 or t == 445 or t == 446 then p.start = true end
        \\  if t == 360 or t == 361 then p.a = true end
        \\  if t == 370 or t == 371 or t == 380 or t == 381 then p.b = true end
        \\  return p
        \\end
        \\local function mapRow(row, text)
        \\  for i = 1, #text do
        \\    local a = DEBUG_MAP + (row * 32 + 2 + i - 1) * 2
        \\    local got = emu.read(a, vram) | (emu.read(a + 1, vram) << 8)
        \\    if got ~= 0x100 + string.byte(text, i) then return false end
        \\  end
        \\  return true
        \\end
        \\local function closedAgain(t, vram_too)
        \\  if emu.read(R_OPEN, wram) ~= 0 or emu.read(R_PAUSED, wram) ~= 0 then fail(123, t, "up or paused", "closed, playing") end
        \\  for i, v in ipairs(bandTms()) do if v ~= dbg.tm[i] then fail(123, t, "band " .. i .. " " .. v, dbg.tm[i]) end end
        \\  if vram_too and vramSum() ~= dbg.sum then fail(124, t) end
        \\end
        \\function debugStep(t)
        \\  dbg.stage = dbg.stage or 0
        \\  if dbg.stage == 0 and t >= 349 then
        \\    if t ~= 349 then fail(122, t, "pass " .. t, "before the chord") end
        \\    dbg.tm, dbg.sum, dbg.x, dbg.stage = bandTms(), vramSum(), rd16(R.x, wram), 1
        \\  elseif dbg.stage == 1 and t >= 356 then
        \\    dbg.stage = 2
        \\    if emu.read(R_OPEN, wram) == 0 then fail(122, t, "closed", "open") end
        \\    if emu.read(R_PAUSED, wram) ~= 0 then fail(122, t, "paused", "the menu's frame") end
        \\    if rd16(R.x, wram) ~= dbg.x then fail(122, t, "x " .. rd16(R.x, wram), dbg.x) end
        \\    for i, v in ipairs(bandTms()) do if v ~= TM_BG1 then fail(122, t, "band " .. i .. " " .. v, TM_BG1) end end
        \\    if not mapRow(1, "DEBUG") then fail(122, t, "root", "DEBUG") end
        \\    for i = 1, #FONT_A_BYTES do
        \\      if emu.read(FONT_A + i - 1, vram) ~= FONT_A_BYTES[i] then fail(122, t, "font byte " .. i, FONT_A_BYTES[i]) end
        \\    end
        \\    if vramSum() ~= dbg.sum then fail(124, t) end
        \\  elseif dbg.stage == 2 and t >= 366 then
        \\    dbg.stage = 3
        \\    if not mapRow(1, "SAMUS") then fail(122, t, "page", "SAMUS") end
        \\  elseif dbg.stage == 3 and t >= 376 then
        \\    dbg.stage = 4
        \\    if emu.read(R_OPEN, wram) == 0 or not mapRow(1, "DEBUG") then fail(123, t, "B", "back at the root") end
        \\  elseif dbg.stage == 4 and t >= 386 then
        \\    dbg.stage = 5
        \\    closedAgain(t, true)
        \\  elseif dbg.stage == 5 and t >= 421 then
        \\    dbg.stage = 6
        \\    if rd16(R.x, wram) <= dbg.x then fail(123, t, "x " .. rd16(R.x, wram), "past " .. dbg.x) end
        \\  elseif dbg.stage == 6 and t >= 436 then
        \\    dbg.stage = 7
        \\    if emu.read(R_OPEN, wram) == 0 then fail(122, t, "closed", "open again") end
        \\  elseif dbg.stage == 7 and t >= 451 then
        \\    -- She has walked since, and walking streams the map: the layers only.
        \\    closedAgain(t, false)
        \\    if not stopped then emu.stop(0) end
        \\  end
        \\end
        \\
        \\-- The end of a pass.
        \\emu.addMemoryCallback(function()
        \\  if stopped then return end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(112, t) end
        \\  -- A retail cart's menu, before the counter: its first frame is long.
        \\  if not DEBUG_RUN and emu.read(R_OPEN, wram) ~= 0 then fail(121, t, "menu up", "no menu") end
        \\  local fc = rd16(R.frames, wram)
        \\  if phase == 2 then
        \\    if rd16(R.countdown, wram) ~= ANCHOR_CD then return end
        \\    phase, t, anchor_fc = 3, 0, fc
        \\  elseif phase == 3 then
        \\    -- The debug screen's first frame is long -- the font widened and
        \\    -- the page drawn in one pass -- and it is tooling, not the game's,
        \\    -- so its run keeps time by the counter and does not require it.
        \\    if not DEBUG_RUN and fc - anchor_fc ~= t + 1 then fail(113, t) end
        \\    t = fc - anchor_fc
        \\  else
        \\    return
        \\  end
        \\  if emu.read(R.debug, wram) ~= 0 then fail(121, t, "debugFlag " .. emu.read(R.debug, wram), 0) end
        \\  if DEBUG_RUN then debugStep(t) return end
        \\  local s = ST[t + 1]
        \\  -- First, because it is a cause of causes: the flash, the
        \\  -- appearance's flicker and the walk's alternation all read it.
        \\  if fc & 0xFF ~= s[12] then fail(120, t, fc & 0xFF, s[12]) end
        \\  local n = 0
        \\  local u = 0
        \\  for i = 0, rd16(R.rec_len, wram) - 2, 2 do
        \\    if emu.read(R.rec + i, wram) == REQ_PAUSE then
        \\      local v = emu.read(R.rec + i + 1, wram)
        \\      if v == 1 then n = n + 1 elseif v == 2 then u = u + 1 end
        \\    end
        \\  end
        \\  if n ~= s[8] or u ~= s[9] then fail(119, t, n .. "/" .. u, s[8] .. "/" .. s[9]) end
        \\  if emu.read(R.bgp, wram) ~= s[1] then fail(114, t, emu.read(R.bgp, wram), s[1]) end
        \\  if SHOWN ~= nil and ((SHOWN & 0x8F) == 0x0F) ~= (s[1] == 0x93) then fail(125, t, SHOWN, s[1]) end
        \\  local pos = rd16(R.x, wram) .. "," .. rd16(R.y, wram) .. "," .. emu.read(R.pose, wram)
        \\  if pos ~= s[2] .. "," .. s[3] .. "," .. s[4] then fail(115, t, pos, s[2] .. "," .. s[3] .. "," .. s[4]) end
        \\  local igt = emu.read(R.igt_s, wram) .. "," .. emu.read(R.igt_m, wram) .. "," .. emu.read(R.igt_h, wram)
        \\  if igt ~= s[5] .. "," .. s[6] .. "," .. s[7] then fail(116, t, igt, s[5] .. "," .. s[6] .. "," .. s[7]) end
        \\  local bar = hex(R.bar, 20, vram, 2)
        \\  if bar ~= s[10] then fail(117, t, bar, s[10]) end
        \\  local objs = hex(R.oam + 2, #s[11] // 2, wram, 4)
        \\  if objs ~= s[11] then fail(118, t, objs, s[11]) end
        \\  if t + 1 == #ST then emu.stop(0) end
        \\end, emu.callbackType.exec, COMMIT, COMMIT, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\-- The title and the new game, and the watchdog.
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(110, t) end
        \\  if phase == 0 and rd16(R.frames, wram) ~= 0 then phase = 1 end
        \\  if phase < 3 and frames > 1200 then fail(111, 0) end
        \\end, emu.eventType.endFrame)
        \\
        \\-- The pad. In play, pass k reads the poll made at vblank k - 1, which
        \\-- NMI k's `PublishPad` hands on; and this event fires before NMI k - 1
        \\-- counts that vblank, so the counter reads k - 2 here. On the title,
        \\-- Start for a new game as the title rung places a press against
        \\-- `title_oracle`'s frame-at-a-time Game Boy: its frames 5 and 6.
        \\emu.addEventCallback(function()
        \\  local fc = rd16(R.frames, wram)
        \\  if phase == 1 then
        \\    local p = {{}}
        \\    if fc + 1 == 5 or fc + 1 == 6 then
        \\      p.start = true
        \\      starts = starts + 1
        \\      if starts == 2 then phase = 2 end
        \\    end
        \\    emu.setInput(p, 0)
        \\    return
        \\  end
        \\  if phase ~= 3 then return end
        \\  if DEBUG_RUN then emu.setInput(debugPad(fc + 2 - anchor_fc), 0) return end
        \\  local p = PAD[fc + 2 - anchor_fc + 1]
        \\  if p ~= nil then
        \\    -- The combo run: L and R held around the Start at 350, the chord a
        \\    -- debug cart would take for its menu.
        \\    local tt = fc + 2 - anchor_fc
        \\    if COMBO and tt >= 345 and tt <= 352 then
        \\      local q = {{ l = true, r = true }}
        \\      for k, v in pairs(p) do q[k] = v end
        \\      p = q
        \\    end
        \\    emu.setInput(p, 0)
        \\  end
        \\end, emu.eventType.inputPolled)
        \\
    , .{});
}
