//! A second channel out of a headless Mesen2 run: the cartridge's save RAM.
//!
//! `oracle.zig` grades the port through the process exit code, because that is
//! the only thing a `--testrunner` run gives back -- `emu.log` is swallowed and
//! lua's `io` is nil, both measured rather than assumed. One byte is enough to
//! say *when* the two machines disagreed, which is what a gate needs.
//!
//! It is not enough to say *why*, and Step 15's first honest divergence is a
//! frame the port walks into and the original walks out of. So this file opens
//! a wider channel, out of the same sandbox, by asking the emulator to do what
//! it already does for every game that has a battery: **write the cartridge's
//! save RAM to disk when the machine powers off.**
//!
//! The cart the builder ships declares no SRAM and gains none here. This file
//! re-stamps a *copy* of the header - cartridge type and RAM size, then the
//! checksum pair over the result - so the traced cart is the shipped cart plus
//! a scratch buffer no engine code touches. The script writes one record per
//! frame into it through `emu.write(..., emu.memType.snesSaveRam)`, and Mesen
//! saves it beside its other `.srm` files on exit.
//!
//! Sampled at the same instant as the oracle, for the same reason: the top of
//! `MainLoop` is the engine's commit point. A trace taken anywhere else would
//! not line up with the comparator that sent us looking.
//!
//! No address in the record is written down. Every field names a label in
//! `engine.sym`, the way `correspond.zig` does, so a variable that moves moves
//! here too or the resolve fails loudly.

const std = @import("std");
const inject = @import("snes_inject.zig");
const oracle = @import("oracle.zig");

pub const Error = error{
    MissingSymbol,
    NoSaveFolder,
    NoSaveFile,
    ShortSaveFile,
    TooManyFrames,
    OutOfMemory,
};

// ---- The record -----------------------------------------------------------

pub const Field = struct {
    /// What the column is called when the trace is printed.
    name: []const u8,
    /// The label in `engine.sym` that carries its address. See the `Var*` block
    /// in `engine/main.asm`.
    sym: []const u8,
    /// One byte or two, matching the variable's own width.
    width: u2,
};

/// What a frame of the port's movement state is.
///
/// Chosen to answer the question the oracle raises and no more: what the engine
/// was handed (`pressed`, `edge`), what it dispatched on (`pose`, `facing`,
/// the timers), where it started and ended the frame (`prev_x`, `samus_x`), and
/// what the collision said when it refused a step (`block`, `hit`, `solid`).
pub const fields = [_]Field{
    .{ .name = "frame", .sym = "VarFrameCount", .width = 2 },
    .{ .name = "map", .sym = "VarMapIndex", .width = 1 },
    .{ .name = "cell", .sym = "VarCell", .width = 1 },
    .{ .name = "samus_x", .sym = "VarSamusX", .width = 2 },
    .{ .name = "samus_y", .sym = "VarSamusY", .width = 2 },
    .{ .name = "prev_x", .sym = "VarPrevX", .width = 2 },
    .{ .name = "prev_y", .sym = "VarPrevY", .width = 2 },
    .{ .name = "cam_x", .sym = "VarCamX", .width = 2 },
    .{ .name = "cam_y", .sym = "VarCamY", .width = 2 },
    .{ .name = "held", .sym = "VarPadHeld", .width = 2 },
    .{ .name = "pressed", .sym = "VarInputPressed", .width = 2 },
    .{ .name = "edge", .sym = "VarInputRisingEdge", .width = 2 },
    .{ .name = "pose", .sym = "VarPose", .width = 1 },
    .{ .name = "facing", .sym = "VarFacing", .width = 1 },
    .{ .name = "jump_arc", .sym = "VarJumpArc", .width = 1 },
    .{ .name = "fall_arc", .sym = "VarFallArc", .width = 1 },
    .{ .name = "turn", .sym = "VarTurnTimer", .width = 1 },
    .{ .name = "anim", .sym = "VarAnimTimer", .width = 1 },
    .{ .name = "water", .sym = "VarWater", .width = 1 },
    .{ .name = "unhandled", .sym = "VarUnhandled", .width = 1 },
    .{ .name = "solid", .sym = "VarSolid", .width = 1 },
    .{ .name = "block", .sym = "VarBlock", .width = 1 },
    .{ .name = "hit", .sym = "VarHit", .width = 1 },
    .{ .name = "speed_r", .sym = "VarSpeedR", .width = 1 },
    .{ .name = "speed_l", .sym = "VarSpeedL", .width = 1 },
    .{ .name = "move_b", .sym = "VarMoveB", .width = 2 },
    .{ .name = "tile_x", .sym = "VarTileX", .width = 2 },
    .{ .name = "tile_y", .sym = "VarTileY", .width = 2 },
    // B4b's four, and the reason they are here: every column above is about
    // Samus, and a rung that says "Samus's position diverged" on the frame an
    // enemy touches her cannot tell "the port did not register the hit" from
    // "the port's enemy is not where the reference's is". Slot 0 only -- the
    // record is a fixed-width channel through save RAM and sixteen slots would
    // not fit -- which is enough for the segment, whose Senjoo is slot 0. Four
    // columns and not more for the same reason: the channel is 32 KiB, the
    // record is 45 bytes with these four in it, and 700 frames plus the tilemap
    // is 32 524 of the 32 768 there are. `!EnTotal` was the fifth and had to go
    // back out; the test below is what said so.
    .{ .name = "en_st", .sym = "VarSlot0Status", .width = 1 },
    .{ .name = "en_y", .sym = "VarSlot0Y", .width = 1 },
    .{ .name = "en_x", .sym = "VarSlot0X", .width = 1 },
    .{ .name = "en_spr", .sym = "VarSlot0Spr", .width = 1 },
};

/// The 32x32 tilemap the engine's collision reads, copied out after the last
/// frame: one byte per tile, the low half of each word, which is the Game Boy
/// tile id `SampleTile` looks up.
pub const tilemap_tiles: usize = 32 * 32;
pub const tilemap_symbol = "VarTilemapBuf";

pub const record_bytes: usize = blk: {
    var n: usize = 0;
    for (fields) |f| n += f.width;
    break :blk n;
};

/// Where a field's bytes sit inside one record.
pub fn offsetOf(comptime name: []const u8) usize {
    return comptime blk: {
        var n: usize = 0;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) break :blk n;
            n += f.width;
        }
        @compileError("no trace field named " ++ name);
    };
}

/// One frame, as bytes, with the record's own layout to read it by.
pub const Snapshot = struct {
    bytes: []const u8,

    pub fn get(self: Snapshot, comptime name: []const u8) u16 {
        const off = offsetOf(name);
        const w = comptime widthOf(name);
        return if (w == 1)
            self.bytes[off]
        else
            @as(u16, self.bytes[off]) | (@as(u16, self.bytes[off + 1]) << 8);
    }
};

fn widthOf(comptime name: []const u8) u2 {
    return comptime blk: {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) break :blk f.width;
        }
        @compileError("no trace field named " ++ name);
    };
}

// ---- The cartridge's scratch buffer ---------------------------------------

/// 32 KiB, the largest a LoROM cart addresses in one bank, which at 51 bytes a
/// frame is six hundred frames of segment. The oracle's is three hundred and
/// twenty.
pub const sram_bytes: usize = 32 * 1024;
pub const sram_size_byte: u8 = 5; // log2 of the size in KiB
/// ROM + RAM + battery. The battery is what makes Mesen write the file.
pub const cart_type_byte: u8 = 0x02;

pub fn maxFrames() usize {
    return (sram_bytes - tilemap_tiles) / record_bytes;
}

/// Re-stamp a finished cart's header so the emulator gives it save RAM.
///
/// The two bytes, then the checksum pair over the result, by the same
/// convention `snes_inject.patchHeader` uses: the fields read $FFFF and $0000
/// while the sum is taken. Done here rather than in the engine because the
/// shipped cart has no battery and should not grow one for a debugging tool.
pub fn stampSram(bytes: []u8) Error!void {
    return stampSramOf(bytes, sram_size_byte);
}

/// `stampSram` with another size, `size_byte` being log2 of the KiB. The enemy
/// oracle's cart takes 64 KiB (1.0 Step 8b): past one LoROM bank the engine
/// could not address it, but the engine never looks -- the script writes the
/// records through Mesen's `snesSaveRam`, which is one flat array.
pub fn stampSramOf(bytes: []u8, size_byte: u8) Error!void {
    const header = inject.symbolOffset("CartHeader") orelse return Error.MissingSymbol;
    bytes[header + 0x16] = cart_type_byte;
    bytes[header + 0x18] = size_byte;
    const complement = (inject.symbolOffset("ChecksumComplement") orelse return Error.MissingSymbol);
    const checksum = (inject.symbolOffset("Checksum") orelse return Error.MissingSymbol);
    std.mem.writeInt(u16, bytes[complement..][0..2], 0xFFFF, .little);
    std.mem.writeInt(u16, bytes[checksum..][0..2], 0x0000, .little);
    var sum: u16 = 0;
    for (bytes) |b| sum +%= b;
    std.mem.writeInt(u16, bytes[checksum..][0..2], sum, .little);
    std.mem.writeInt(u16, bytes[complement..][0..2], ~sum, .little);
}

// ---- Where Mesen puts the file --------------------------------------------

/// The folders Mesen2 keeps its saves in, most likely first.
///
/// Probed rather than configured: Mesen2 has no command line option for it, and
/// the `HOME` environment variable does not move it on macOS - both measured.
/// The build ships two names because the macOS app bundle in use here calls
/// itself MesenCE and upstream calls itself Mesen2.
const save_folders = [_][]const u8{
    "Library/Application Support/MesenCE/Saves",
    "Library/Application Support/Mesen2/Saves",
    ".config/MesenCE/Saves",
    ".config/Mesen2/Saves",
};

pub fn savePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    rom_stem: []const u8,
) Error![]u8 {
    if (home.len == 0) return Error.NoSaveFolder;
    for (save_folders) |rel| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, rel });
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        dir.close(io);
        defer allocator.free(path);
        return try std.fmt.allocPrint(allocator, "{s}/{s}.srm", .{ path, rom_stem });
    }
    return Error.NoSaveFolder;
}

// ---- The generated script -------------------------------------------------

/// Write the trace script for a cart that has been stamped with save RAM.
///
/// The same input schedule and the same sampling point as the oracle's script,
/// and no comparison at all: this one records, and the reading happens on this
/// side where there is somewhere to put the answer.
/// `keys` is the input schedule, one entry per frame, and its length is how
/// many frames are traced.
///
/// **It used to be a frame count, with the schedule read straight out of
/// `oracle.keyAt`.** That made the tracer able to reproduce exactly one thing:
/// the hand-authored segment. The re-anchored comparison grades thirteen
/// stretches of a published run, each with its own schedule, and "why did the
/// cart do that" is the question that matters most on the twelve the segment
/// cannot answer for.
pub fn writeLua(keys: []const oracle.Key, w: *std.Io.Writer) !void {
    const frames = keys.len;
    if (frames > maxFrames()) return Error.TooManyFrames;
    const commit = inject.symbol(oracle.commit_symbol) orelse return Error.MissingSymbol;

    try w.print(
        \\-- Generated by `zig build trace`. Do not edit.
        \\--
        \\-- Records one {d}-byte record per frame into the cart's save RAM, which
        \\-- Mesen2 writes to disk on power-off. That is the only wide channel out
        \\-- of a testrunner run: emu.log is swallowed and lua's io is nil.
        \\--
        \\-- Sampled at the top of MainLoop, the engine's commit point, so a row
        \\-- here is the same instant the oracle compares. See src/oracle.zig.
        \\
        \\local wram = emu.memType.snesWorkRam
        \\local sram = emu.memType.snesSaveRam
        \\local COMMIT = 0x{X:0>6}
        \\local FRAMES = {d}
        \\local REC = {d}
        \\local TILEMAP = 0x{X:0>4}
        \\local TILES = {d}
        \\
        \\-- {{ address, width }}, resolved from engine.sym by src/snes_trace.zig.
        \\local F = {{
        \\
    , .{
        record_bytes,
        commit,
        frames,
        record_bytes,
        @as(u16, @truncate(inject.symbol(tilemap_symbol) orelse return Error.MissingSymbol)),
        tilemap_tiles,
    });

    for (fields) |f| {
        const addr = inject.symbol(f.sym) orelse return Error.MissingSymbol;
        try w.print("  {{0x{X:0>4},{d}}}, -- {s}\n", .{ @as(u16, @truncate(addr)), f.width, f.name });
    }

    try w.print("}}\n\n", .{});

    try w.print("local KEYS = {{\n", .{});
    var keybuf: [oracle.mesen_keys_max]u8 = undefined;
    for (keys) |k| {
        try w.print("  {{{s}}},\n", .{oracle.mesenKeys(k, &keybuf)});
    }
    try w.print("}}\n\n", .{});

    try w.print(
        \\local i = 0
        \\local hold = nil
        \\
        \\emu.addMemoryCallback(function()
        \\  if i > 0 and i <= FRAMES then
        \\    local at = (i - 1) * REC
        \\    for k = 1, #F do
        \\      local a, width = F[k][1], F[k][2]
        \\      emu.write(at, emu.read(a, wram), sram)
        \\      at = at + 1
        \\      if width == 2 then
        \\        emu.write(at, emu.read(a + 1, wram), sram)
        \\        at = at + 1
        \\      end
        \\    end
        \\    if i == FRAMES then
        \\      -- The world the engine was walking through, after the records so
        \\      -- the frame layout above stays a plain array.
        \\      local at2 = FRAMES * REC
        \\      for k = 0, TILES - 1 do
        \\        emu.write(at2 + k, emu.read(TILEMAP + k * 2, wram), sram)
        \\      end
        \\      emu.stop(0)
        \\    end
        \\  end
        \\  i = i + 1
        \\  hold = KEYS[i]
        \\end, emu.callbackType.exec, COMMIT, COMMIT, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\emu.addEventCallback(function()
        \\  if hold ~= nil then emu.setInput(hold, 0) end
        \\end, emu.eventType.inputPolled)
        \\
        \\-- A cart that never reaches MainLoop would time out with an empty file,
        \\-- which reads as a tooling problem rather than a boot one. Stopping
        \\-- early leaves the save RAM zeroed, and `run` says so.
        \\local watchdog = 0
        \\emu.addEventCallback(function()
        \\  watchdog = watchdog + 1
        \\  if i == 0 and watchdog > 120 then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{});
}

// ---- Where the floor is -----------------------------------------------------

/// Where Samus is standing relative to the ground the engine can see.
///
/// James watched the oracle's cart in an emulator and said it plainly: she
/// spawns *below* the floor tiles, and one jump lifts her out, after which she
/// lands and moves normally. That is worth catching by machine rather than by
/// eye, and it is a different question from `oracle.World` -- the two machines
/// can be standing in the same room and the boot record can still drop her into
/// it at the wrong height.
///
/// The probe is `CollideBottom`'s own: `SetTileX` with `ORIGIN_X_LEFT + 1`,
/// `SetTileY` with `ORIGIN_Y_BOTTOM`, and `SampleTile` subtracting the two OAM
/// biases straight back off. The offsets come out of `engine.sym` rather than
/// being written down here, so they cannot drift from the engine that uses them.
pub const Footing = struct {
    /// Tile row her feet probe lands in.
    feet_row: usize,
    /// The first solid row at or below her head, or null if there is none.
    surface_row: ?usize,
    /// Tile column the probe uses.
    col: usize,
    /// How far she is inside the ground, in pixels. Zero when she is standing
    /// on it; negative is not represented because a Samus in the air is simply
    /// falling.
    embedded: usize = 0,
    /// The pixel row that would put her feet in the surface row.
    wants_pixel_y: ?u8 = null,

    pub fn standing(self: Footing) bool {
        return self.surface_row != null and self.embedded == 0;
    }
};

/// Read the footing out of a cart's own tilemap and solidity threshold.
///
/// `tiles` and `solid` both come from the running cart, so this asks what the
/// engine would answer rather than what a model of it would.
pub fn footing(tiles: []const u8, solid: u8, pixel_x: u8, pixel_y: u8) Error!Footing {
    const x_left: u16 = @truncate(inject.symbol("ConstOriginXLeft") orelse return Error.MissingSymbol);
    const y_bottom: u16 = @truncate(inject.symbol("ConstOriginYBottom") orelse return Error.MissingSymbol);

    // `SetTileX` adds the OAM bias and `SampleTile` takes it off again, so the
    // world coordinate is the pixel plus the origin offset and nothing else.
    const probe_x: u16 = (@as(u16, pixel_x) + x_left + 1) & 0xFF;
    const probe_y: u16 = (@as(u16, pixel_y) + y_bottom) & 0xFF;
    const col: usize = (probe_x & 0xF8) >> 3;
    const feet_row: usize = (probe_y & 0xF8) >> 3;

    // Walk down her own column from the top of the map to the feet probe: the
    // first solid row is the surface she should be resting on.
    var surface: ?usize = null;
    for (0..feet_row + 1) |r| {
        if (tiles[r * 32 + col] < solid) {
            surface = r;
            break;
        }
    }

    var f: Footing = .{ .feet_row = feet_row, .surface_row = surface, .col = col };
    if (surface) |sr| {
        if (feet_row > sr) {
            f.embedded = (feet_row - sr) * 8;
            const want = @as(isize, @intCast(sr * 8)) - @as(isize, @intCast(y_bottom));
            if (want >= 0 and want <= 255) f.wants_pixel_y = @intCast(want);
        }
    }
    return f;
}

// ---- Running it -----------------------------------------------------------

pub const out_dir = "build-out";
pub const stem = "trace";
pub const cart_name = out_dir ++ "/" ++ stem ++ ".sfc";
pub const lua_name = out_dir ++ "/" ++ stem ++ ".lua";

pub const Run = struct {
    /// One `record_bytes` slice per frame, in order.
    rows: [][]const u8,
    /// The engine's own 32x32 tilemap, one tile id per byte, as it stood on the
    /// segment's last frame.
    tilemap: []const u8,
    /// The emulator's exit code, for the boot failures the script can name.
    code: u8,
    backing: []u8,

    pub fn at(self: Run, frame: usize) Snapshot {
        return .{ .bytes = self.rows[frame] };
    }

    pub fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        allocator.free(self.backing);
    }
};

/// Build the traced cart from a finished image, run it, and read the records
/// back out of the emulator's save file.
///
/// `cart` is the cart the oracle built, unmodified: this copies it, stamps the
/// copy, and leaves the original alone.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cart: []const u8,
    keys: []const oracle.Key,
    mesen_path: []const u8,
    home: []const u8,
) !Run {
    const frames = keys.len;
    const stamped = try allocator.dupe(u8, cart);
    defer allocator.free(stamped);
    try stampSram(stamped);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".sfc", .data = stamped });

    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeLua(keys, &lua.writer);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".lua", .data = lua.written() });

    const srm = try savePath(allocator, io, home, stem);
    defer allocator.free(srm);
    // A stale file from an earlier run would read as a successful one.
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{ mesen_path, cart_name, "--testrunner", lua_name, "--timeout=120" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, srm, allocator, .limited(sram_bytes * 2)) catch
        return Error.NoSaveFile;
    errdefer allocator.free(bytes);
    if (bytes.len < frames * record_bytes + tilemap_tiles) return Error.ShortSaveFile;

    const rows = try allocator.alloc([]const u8, frames);
    for (0..frames) |f| rows[f] = bytes[f * record_bytes ..][0..record_bytes];
    return .{
        .rows = rows,
        .tilemap = bytes[frames * record_bytes ..][0..tilemap_tiles],
        .code = code,
        .backing = bytes,
    };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "the record is small enough that the segment and the tilemap fit in one save file" {
    try testing.expect(record_bytes > 0);
    try testing.expect(oracle.segment_frames <= maxFrames());
    try testing.expect(oracle.segment_frames * record_bytes + tilemap_tiles <= sram_bytes);
}

test "every field names a label the engine actually exports" {
    // The point of the `Var*` block: a variable that moves takes its symbol
    // with it, and a field that outlives its variable fails here rather than
    // recording whatever now lives at a remembered address.
    for (fields) |f| {
        if (inject.symbol(f.sym) == null) {
            std.debug.print("engine.sym has no {s}\n", .{f.sym});
            return error.MissingSymbol;
        }
    }
}

test "field offsets are distinct and cover the record exactly" {
    var seen: [record_bytes]bool = @splat(false);
    var n: usize = 0;
    inline for (fields) |f| {
        const off = offsetOf(f.name);
        try testing.expectEqual(n, off);
        for (0..f.width) |k| {
            try testing.expect(!seen[off + k]);
            seen[off + k] = true;
        }
        n += f.width;
    }
    try testing.expectEqual(record_bytes, n);
    for (seen) |s| try testing.expect(s);
}

test "stamping save RAM leaves a header the checksum convention accepts" {
    const header = inject.symbolOffset("CartHeader") orelse return error.SkipZigTest;
    var bytes = try testing.allocator.alloc(u8, 512 * 1024);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0x5A);
    try stampSram(bytes);

    try testing.expectEqual(cart_type_byte, bytes[header + 0x16]);
    try testing.expectEqual(sram_size_byte, bytes[header + 0x18]);

    const complement = inject.symbolOffset("ChecksumComplement").?;
    const checksum = inject.symbolOffset("Checksum").?;
    const c = std.mem.readInt(u16, bytes[checksum..][0..2], .little);
    try testing.expectEqual(c, ~std.mem.readInt(u16, bytes[complement..][0..2], .little));
    var sum: u16 = 0;
    for (bytes) |b| sum +%= b;
    try testing.expectEqual(c, sum);
}
