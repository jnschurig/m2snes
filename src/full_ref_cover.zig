//! Coverage of the full scheme's slot assignment (colorization Step 5).
//!
//! `src/full_assign.zig` gives every graphics tile of banks 5-8 a slot, read
//! statically. That can't say which of those tiles the game actually shows.
//! This replays James's 100% recording on the **original** ROM in Mesen, as
//! `gb_trace` does, and records which source tiles were on screen, on which
//! layer. A tile it never sees has a slot nobody has looked at.
//!
//! **Which source tile is in each VRAM tile.** The Game Boy keeps no record of
//! where VRAM's bytes came from, so the script tracks it. A write callback on
//! tile data (`$8000-$97FF`) fires on each tile's first byte. The copy loops
//! that write it all read the byte from ROM just before: `copyToVram`
//! (00:038A) and `VBlank_vramDataTransfer` (00:2BA3) with `LD A,(HL+)`,
//! `VBlank_variaAnimation` (00:2BF4) with `LD A,(DE)`. So the source is
//! HL-1, HL or DE in the bank mapped at `$4000` (`cart.prgBank`). A candidate
//! counts only if it is the first byte of a graphics tile and that byte equals
//! the value written. Anything else (a clear, a copy from RAM) marks the tile
//! unknown. The self-check below compares each tracked tile's VRAM bytes
//! with its source's ROM bytes at the end of every part.
//!
//! **Parts run side by side.** Each `.mmo` part starts from a savestate, so
//! the tiles already in VRAM at its start were copied in an earlier part.
//! The script marks them *initial*, and records which of them were shown;
//! this file then takes their sources from the previous part's final table.
//! The first part's initial tiles are matched by content, where exactly one
//! source tile has the bytes.
//!
//! The script also keeps every save record the game writes (game mode `$09`),
//! with the slot's spawn flags. The SameBoy half boots the patched ROM from
//! them, one per area.

const std = @import("std");
const offsets = @import("offsets.zig");
const gb_trace = @import("gb_trace.zig");
const save = @import("save.zig");

pub const Error = error{
    /// The script did not leave its magic: it did not run, or did not finish.
    DidNotRun,
    /// The layout below does not fit the trace region of cart RAM.
    TooBig,
};

const bank_size = offsets.bank_size;

/// VRAM tiles `$8000-$97FF`.
pub const vram_tiles = 384;
pub const vram_tile_bytes = vram_tiles * 16;

/// A graphics tile of `offsets.zig`: its entry, its index in the entry, and
/// its offset in the ROM.
pub const Source = struct { entry: u16, tile: u16, flat: u32 };

/// Every graphics tile of banks 5-8, in `offsets.entries` order (the order of
/// `full_assign.regions`).
pub fn sources(allocator: std.mem.Allocator) ![]Source {
    var list: std.ArrayList(Source) = .empty;
    for (offsets.entries, 0..) |e, i| {
        if (!isGraphics(e.kind)) continue;
        for (0..e.size / 16) |t| try list.append(allocator, .{
            .entry = @intCast(i),
            .tile = @intCast(t),
            .flat = @intCast(e.romOffset() + t * 16),
        });
    }
    return list.toOwnedSlice(allocator);
}

pub fn isGraphics(kind: offsets.Kind) bool {
    return switch (kind) {
        .graphics_enemy, .graphics_item, .graphics_samus, .graphics_tileset, .graphics_ui => true,
        else => false,
    };
}

// ---- What a VRAM tile holds ----------------------------------------------

/// A VRAM tile's source: an index into `sources`, or one of these.
pub const initial: u16 = 0xFFFE;
pub const unknown: u16 = 0xFFFF;

/// Layers a tile was shown on, as the script's bits.
pub const seen_bg: u8 = 1;
pub const seen_window: u8 = 2;
pub const seen_obp0: u8 = 4;
pub const seen_obp1: u8 = 8;
pub const seen_background = seen_bg | seen_window;
pub const seen_sprite = seen_obp0 | seen_obp1;

// ---- The cart-RAM layout --------------------------------------------------

pub const magic = [4]u8{ 'G', 'B', 'C', '1' };

/// A save the game wrote: the movie frame, the slot, the slot's 64 bytes and
/// its spawn flags.
pub const save_bytes: usize = 4 + 1 + save.slot_size + save.spawn_size;

pub const Layout = struct {
    nsrc: usize,
    src_end: usize,
    seen: usize,
    iseen: usize,
    useen: usize,
    visited: usize,
    vram_start: usize,
    vram_end: usize,
    saves: usize,
    max_saves: usize,

    pub fn of(nsrc: usize) Error!Layout {
        var at: usize = gb_trace.records_at;
        var l: Layout = undefined;
        l.nsrc = nsrc;
        l.src_end = at;
        at += vram_tiles * 2;
        l.seen = at;
        at += nsrc;
        l.iseen = at;
        at += vram_tiles;
        l.useen = at;
        at += vram_tiles;
        l.visited = at;
        at += visited_bytes;
        l.vram_start = at;
        at += vram_tile_bytes;
        l.vram_end = at;
        at += vram_tile_bytes;
        l.saves = at;
        if (at > gb_trace.sram_bytes) return Error.TooBig;
        l.max_saves = (gb_trace.sram_bytes - at) / save_bytes;
        if (l.max_saves < 4) return Error.TooBig;
        return l;
    }
};

/// One bit per (map bank, cell), banks 0-15.
pub const visited_bytes: usize = 16 * 256 / 8;

// ---- The script -----------------------------------------------------------

/// The coverage script for one part.
pub fn writeLua(w: *std.Io.Writer, rec: gb_trace.Recording, srcs: []const Source, offset: usize) !void {
    const l = try Layout.of(srcs.len);
    try w.print(
        \\-- Generated by src/full_ref_cover.zig. Do not edit.
        \\
        \\local STATE =
    , .{});
    try gb_trace.writeLuaBytes(w, rec.state);
    try w.print("\nlocal IN = ", .{});
    try gb_trace.writeLuaBytes(w, rec.inputs);
    // First byte of each graphics tile -> its source index. Aliased bytes
    // keep the first; this file folds aliases together afterwards.
    try w.print("\n\nlocal TILE = {{", .{});
    var seen_flat = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    defer seen_flat.deinit();
    for (srcs, 0..) |s, i| {
        if ((try seen_flat.getOrPut(s.flat)).found_existing) continue;
        if (i % 16 == 0) try w.print("\n", .{});
        try w.print("[{d}]={d},", .{ s.flat, i });
    }
    try w.print(
        \\
        \\}}
        \\local AT, LAST, NSRC = {d}, {d}, {d}
        \\local O_SRC, O_SEEN, O_ISEEN, O_USEEN, O_VIS = {d}, {d}, {d}, {d}, {d}
        \\local O_VSTART, O_VEND, O_SAVES, MAXSAVE, SAVEB = {d}, {d}, {d}, {d}, {d}
        \\local SLOT_END = {d}
        \\
    , .{
        gb_trace.header_at, rec.frames(),        srcs.len,
        l.src_end,          l.seen,              l.iseen,
        l.useen,            l.visited,           l.vram_start,
        l.vram_end,         l.saves,             l.max_saves,
        save_bytes,         save.record_len - 1,
    });
    try gb_trace.writeDriver(w, offset);
    try w.writeAll(script_body);
}

/// The fixed half of the script. `INITIAL` tiles were in VRAM when the part's
/// savestate loaded; `UNKNOWN` ones were written from no graphics tile.
const script_body =
    \\local vram = emu.memType.gbVideoRam
    \\local oam  = emu.memType.gbSpriteRam
    \\local prg  = emu.memType.gbPrgRom
    \\local INITIAL, UNKNOWN = -2, -1
    \\
    \\local SRC, SEEN, ISEEN, USEEN, VIS = {}, {}, {}, {}, {}
    \\for t = 0, 383 do SRC[t] = INITIAL end
    \\local assigned, unassigned, saves, dropped = 0, 0, 0, 0
    \\
    \\-- VRAM as the savestate left it, before the first write lands.
    \\local dumped = false
    \\local function dumpStart()
    \\  if dumped then return end
    \\  dumped = true
    \\  for a = 0, 6143 do write(O_VSTART + a, read(a, vram), sram) end
    \\end
    \\
    \\-- The source of a tile's first byte: HL-1 (`LD A,(HL+)`), HL, or DE
    \\-- (the Varia animation), whichever is a graphics tile's first byte and
    \\-- holds the value written.
    \\emu.addMemoryCallback(function(addr, value)
    \\  if not loaded or done then return end
    \\  dumpStart()
    \\  if addr & 15 ~= 0 then return end
    \\  local t = (addr - 0x8000) >> 4
    \\  local st = emu.getState()
    \\  local bank = st["cart.prgBank"]
    \\  local hl = (st["cpu.h"] << 8) | st["cpu.l"]
    \\  local de = (st["cpu.d"] << 8) | st["cpu.e"]
    \\  local s = nil
    \\  for _, a in ipairs({ hl - 1, hl, de }) do
    \\    local fl = nil
    \\    if a >= 0 and a < 0x4000 then fl = a
    \\    elseif a >= 0x4000 and a < 0x8000 then fl = bank * 0x4000 + (a - 0x4000) end
    \\    if fl ~= nil and TILE[fl] ~= nil and read(fl, prg) == value then s = TILE[fl]; break end
    \\  end
    \\  if s ~= nil then SRC[t] = s; assigned = assigned + 1
    \\  else SRC[t] = UNKNOWN; unassigned = unassigned + 1 end
    \\end, emu.callbackType.write, 0x8000, 0x97FF, emu.cpuType.gameboy, emu.memType.gameboyMemory)
    \\
    \\-- Every save record, when its last byte is written.
    \\emu.addMemoryCallback(function(addr, value)
    \\  if not loaded or done then return end
    \\  local off = addr - 0xA000
    \\  local slot = off // 64
    \\  if slot > 2 or off % 64 ~= SLOT_END then return end
    \\  if saves >= MAXSAVE then dropped = dropped + 1; return end
    \\  local at = put(O_SAVES + saves * SAVEB, f - OFFSET, 4)
    \\  write(at, slot, sram); at = at + 1
    \\  for i = 0, 63 do
    \\    local v = read(slot * 64 + i, sram)
    \\    if i == SLOT_END then v = value end
    \\    write(at + i, v, sram)
    \\  end
    \\  at = at + 64
    \\  for i = 0, 511 do write(at + i, read(0x1000 + slot * 0x200 + i, sram), sram) end
    \\  saves = saves + 1
    \\end, emu.callbackType.write, 0xA000, 0xA0BF, emu.cpuType.gameboy, emu.memType.gameboyMemory)
    \\
    \\local function mark(t, b)
    \\  local s = SRC[t]
    \\  if s >= 0 then SEEN[s] = (SEEN[s] or 0) | b
    \\  elseif s == INITIAL then ISEEN[t] = (ISEEN[t] or 0) | b
    \\  else USEEN[t] = (USEEN[t] or 0) | b end
    \\end
    \\
    \\-- LCDC bit 4 clear: ids $00-$7F are tiles $100-$17F.
    \\local function bgTile(id, signed)
    \\  if signed and id < 0x80 then return 0x100 + id end
    \\  return id
    \\end
    \\
    \\local function shown()
    \\  local lcdc = read(0xFF40, mem)
    \\  if lcdc & 0x80 == 0 or lcdc & 0x01 == 0 then return end
    \\  local signed = lcdc & 0x10 == 0
    \\  local wy, wx = read(0xFF4A, mem), read(0xFF4B, mem)
    \\  local win = lcdc & 0x20 ~= 0 and wy <= 143 and wx <= 166
    \\  local wxs = wx - 7
    \\  -- Background: the 21x19 tiles under the screen, less what the window
    \\  -- covers (screen lines from WY, columns from WX-7).
    \\  local base = (lcdc & 0x08 ~= 0) and 0x1C00 or 0x1800
    \\  local scy, scx = read(0xFF42, mem), read(0xFF43, mem)
    \\  for k = 0, 18 do
    \\    local top = k * 8 - (scy & 7)
    \\    if top <= 143 then
    \\      local ytop = top < 0 and 0 or top
    \\      local limit = 160
    \\      if win and ytop >= wy then limit = wxs < 0 and 0 or wxs end
    \\      local r = ((scy >> 3) + k) & 31
    \\      for j = 0, 20 do
    \\        local left = j * 8 - (scx & 7)
    \\        local xl = left < 0 and 0 or left
    \\        if xl < limit and left <= 159 then
    \\          mark(bgTile(read(base + r * 32 + (((scx >> 3) + j) & 31), vram), signed), 1)
    \\        end
    \\      end
    \\    end
    \\  end
    \\  if win then
    \\    local wbase = (lcdc & 0x40 ~= 0) and 0x1C00 or 0x1800
    \\    for r = 0, (143 - wy) >> 3 do
    \\      for c = 0, 31 do
    \\        local x = wxs + c * 8
    \\        if x > 159 then break end
    \\        if x + 7 >= 0 then mark(bgTile(read(wbase + r * 32 + c, vram), signed), 2) end
    \\      end
    \\    end
    \\  end
    \\  if lcdc & 0x02 ~= 0 then
    \\    local tall = lcdc & 0x04 ~= 0
    \\    local h = tall and 16 or 8
    \\    for i = 0, 39 do
    \\      local y, x = read(i * 4, oam), read(i * 4 + 1, oam)
    \\      if y > 16 - h and y < 160 and x > 0 and x < 168 then
    \\        local id, at = read(i * 4 + 2, oam), read(i * 4 + 3, oam)
    \\        local b = (at & 0x10 ~= 0) and 8 or 4
    \\        if tall then mark(id & 0xFE, b); mark(id | 1, b) else mark(id, b) end
    \\      end
    \\    end
    \\  end
    \\end
    \\
    \\local function finish()
    \\  done = true
    \\  write(AT + 0, 71, sram); write(AT + 1, 66, sram)
    \\  write(AT + 2, 67, sram); write(AT + 3, 49, sram)
    \\  local at = put(AT + 4, f, 4)
    \\  at = put(at, assigned, 4)
    \\  at = put(at, unassigned, 4)
    \\  at = put(at, saves, 4)
    \\  at = put(at, dropped, 4)
    \\  for t = 0, 383 do
    \\    local s = SRC[t]
    \\    if s == INITIAL then s = 0xFFFE elseif s == UNKNOWN then s = 0xFFFF end
    \\    put(O_SRC + t * 2, s, 2)
    \\  end
    \\  for i = 0, NSRC - 1 do write(O_SEEN + i, SEEN[i] or 0, sram) end
    \\  for t = 0, 383 do
    \\    write(O_ISEEN + t, ISEEN[t] or 0, sram)
    \\    write(O_USEEN + t, USEEN[t] or 0, sram)
    \\  end
    \\  for i = 0, 511 do
    \\    local b = 0
    \\    for k = 0, 7 do if VIS[i * 8 + k] then b = b | (1 << k) end end
    \\    write(O_VIS + i, b, sram)
    \\  end
    \\  for a = 0, 6143 do write(O_VEND + a, read(a, vram), sram) end
    \\  emu.stop(0)
    \\end
    \\
    \\emu.addEventCallback(function()
    \\  if not loaded or done then return end
    \\  dumpStart()
    \\  shown()
    \\  if read(0xFF9B, mem) == 4 then
    \\    local cell = (read(0xFFC1, mem) & 15) * 16 + (read(0xFFC3, mem) & 15)
    \\    VIS[(read(0xD811, mem) & 15) * 256 + cell] = true
    \\  end
    \\  f = f + 1
    \\  if f >= LAST then finish() end
    \\end, emu.eventType.endFrame)
    \\
;

// ---- One part's answer ----------------------------------------------------

pub const Save = struct {
    /// The movie frame the record's last byte was written on.
    frame: u32,
    slot: u8,
    record: [save.slot_size]u8,
    spawn: [save.spawn_size]u8,

    pub fn initial(self: *const Save) ?save.Initial {
        return save.parseInitial(self.record[save.magic_len..save.record_len]);
    }
};

pub const Part = struct {
    frames_run: u32,
    assigned: u32,
    unassigned: u32,
    saves_dropped: u32,
    code: u8,
    /// Each VRAM tile's source at the end: a `sources` index, `initial` or
    /// `unknown`.
    src_end: [vram_tiles]u16,
    /// Per source: the layers it was shown on while tracked.
    seen: []u8,
    /// Per VRAM tile: the layers it was shown on while still initial, and
    /// while unknown.
    iseen: [vram_tiles]u8,
    useen: [vram_tiles]u8,
    visited: [visited_bytes]u8,
    vram_start: [vram_tile_bytes]u8,
    vram_end: [vram_tile_bytes]u8,
    saves: []Save,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, nsrc: usize, code: u8) !Part {
    const l = try Layout.of(nsrc);
    const h = gb_trace.header_at;
    if (bytes.len < gb_trace.sram_bytes or !std.mem.eql(u8, bytes[h..][0..4], &magic)) return Error.DidNotRun;
    const u32At = struct {
        fn f(b: []const u8, at: usize) u32 {
            return std.mem.readInt(u32, b[at..][0..4], .little);
        }
    }.f;
    var p: Part = .{
        .frames_run = u32At(bytes, h + 4),
        .assigned = u32At(bytes, h + 8),
        .unassigned = u32At(bytes, h + 12),
        .saves_dropped = u32At(bytes, h + 20),
        .code = code,
        .src_end = undefined,
        .seen = try allocator.dupe(u8, bytes[l.seen..][0..nsrc]),
        .iseen = bytes[l.iseen..][0..vram_tiles].*,
        .useen = bytes[l.useen..][0..vram_tiles].*,
        .visited = bytes[l.visited..][0..visited_bytes].*,
        .vram_start = bytes[l.vram_start..][0..vram_tile_bytes].*,
        .vram_end = bytes[l.vram_end..][0..vram_tile_bytes].*,
        .saves = undefined,
    };
    for (&p.src_end, 0..) |*s, t| s.* = std.mem.readInt(u16, bytes[l.src_end + 2 * t ..][0..2], .little);
    const n = @min(u32At(bytes, h + 16), l.max_saves);
    p.saves = try allocator.alloc(Save, n);
    for (p.saves, 0..) |*s, i| {
        const at = l.saves + i * save_bytes;
        s.* = .{
            .frame = u32At(bytes, at),
            .slot = bytes[at + 4],
            .record = bytes[at + 5 ..][0..save.slot_size].*,
            .spawn = bytes[at + 5 + save.slot_size ..][0..save.spawn_size].*,
        };
    }
    return p;
}

/// One part, through Mesen (or its cache).
pub fn runPart(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: gb_trace.Recording,
    srcs: []const Source,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
    lane: ?u8,
) !Part {
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeLua(&lua.writer, rec, srcs, offset);
    var code: u8 = 255;
    const bytes = try gb_trace.spawnPassIn(allocator, io, rom, rec, lua.written(), rec.frames(), mesen_path, home, &code, lane);
    defer allocator.free(bytes);
    return parse(allocator, bytes, srcs.len, code);
}

// ---- Putting the parts together -------------------------------------------

/// The source whose 16 bytes are `tile`, if exactly one is (aliases of one
/// ROM tile count once).
pub fn matchContent(rom: []const u8, srcs: []const Source, tile: *const [16]u8) ?u16 {
    var found: ?u16 = null;
    var found_flat: u32 = 0;
    for (srcs, 0..) |s, i| {
        if (!std.mem.eql(u8, rom[s.flat..][0..16], tile)) continue;
        if (found != null and found_flat != s.flat) return null;
        if (found == null) {
            found = @intCast(i);
            found_flat = s.flat;
        }
    }
    return found;
}

/// The part's VRAM tiles as they were at its start, by source: the previous
/// part's end for a later part, a unique content match for the first.
pub fn startSources(rom: []const u8, srcs: []const Source, prev_end: ?*const [vram_tiles]u16, vram_start: *const [vram_tile_bytes]u8) [vram_tiles]u16 {
    var out: [vram_tiles]u16 = undefined;
    for (&out, 0..) |*o, t| {
        if (prev_end) |p| {
            o.* = p[t];
        } else {
            o.* = matchContent(rom, srcs, vram_start[t * 16 ..][0..16]) orelse unknown;
        }
    }
    return out;
}

/// `src_end` with initial tiles taken from `start`.
pub fn resolveEnd(src_end: *const [vram_tiles]u16, start: *const [vram_tiles]u16) [vram_tiles]u16 {
    var out: [vram_tiles]u16 = undefined;
    for (&out, src_end, start) |*o, e, s| o.* = if (e == initial) s else e;
    return out;
}

/// What the whole recording showed.
pub const Coverage = struct {
    /// Per source: the layers it was shown on. Aliases share their bits.
    seen: []u8,
    /// Shown tiles whose source could not be named, counted once per part
    /// and VRAM tile.
    unnamed: usize,
    /// Tracked VRAM tiles whose bytes at a part's end differ from their
    /// source's.
    stale: usize,
    /// Parts whose start VRAM differs from the previous part's end, in tiles.
    seam_tiles: usize,
    visited: [visited_bytes]u8,
};

pub fn combine(allocator: std.mem.Allocator, rom: []const u8, srcs: []const Source, parts: []const Part) !Coverage {
    var c: Coverage = .{
        .seen = try allocator.alloc(u8, srcs.len),
        .unnamed = 0,
        .stale = 0,
        .seam_tiles = 0,
        .visited = @splat(0),
    };
    @memset(c.seen, 0);
    var prev: ?[vram_tiles]u16 = null;
    var prev_vram: ?*const [vram_tile_bytes]u8 = null;
    for (parts) |*p| {
        const start = startSources(rom, srcs, if (prev) |*x| x else null, &p.vram_start);
        for (p.seen, 0..) |b, i| c.seen[i] |= b;
        for (p.iseen, 0..) |b, t| {
            if (b == 0) continue;
            if (start[t] < srcs.len) c.seen[start[t]] |= b else c.unnamed += 1;
        }
        for (p.useen) |b| {
            if (b != 0) c.unnamed += 1;
        }
        // Tiles not written before the dump should carry over unchanged.
        if (prev_vram) |pv| {
            for (0..vram_tiles) |t| {
                if (p.src_end[t] != initial) continue;
                if (!std.mem.eql(u8, pv[t * 16 ..][0..16], p.vram_start[t * 16 ..][0..16])) c.seam_tiles += 1;
            }
        }
        const end = resolveEnd(&p.src_end, &start);
        for (end, 0..) |s, t| {
            if (s >= srcs.len) continue;
            if (!std.mem.eql(u8, rom[srcs[s].flat..][0..16], p.vram_end[t * 16 ..][0..16])) c.stale += 1;
        }
        for (&c.visited, p.visited) |*v, x| v.* |= x;
        prev = end;
        prev_vram = &p.vram_end;
    }
    // Aliases: one ROM tile under two names is seen under both.
    var by_flat = std.AutoHashMap(u32, u8).init(allocator);
    defer by_flat.deinit();
    for (srcs, c.seen) |s, b| {
        const g = try by_flat.getOrPut(s.flat);
        g.value_ptr.* = if (g.found_existing) g.value_ptr.* | b else b;
    }
    for (srcs, c.seen) |s, *b| b.* = by_flat.get(s.flat).?;
    return c;
}

pub fn visitedCell(v: *const [visited_bytes]u8, bank: u8, cell: u8) bool {
    const i = @as(usize, bank & 15) * 256 + cell;
    return v[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

/// A source's coverage as one character of `full_assign.zig`'s `seen`
/// strings: `.` never shown, `b` background or window only, `s` sprite only,
/// `+` both.
pub fn seenChar(bits: u8) u8 {
    const bg = bits & seen_background != 0;
    const spr = bits & seen_sprite != 0;
    if (bg and spr) return '+';
    if (bg) return 'b';
    if (spr) return 's';
    return '.';
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the layout fits the trace region with room for saves" {
    const l = try Layout.of(3000);
    try testing.expect(l.saves + l.max_saves * save_bytes <= gb_trace.sram_bytes);
    try testing.expect(l.max_saves >= 8);
}

test "seen characters" {
    try testing.expectEqual(@as(u8, '.'), seenChar(0));
    try testing.expectEqual(@as(u8, 'b'), seenChar(seen_window));
    try testing.expectEqual(@as(u8, 's'), seenChar(seen_obp1));
    try testing.expectEqual(@as(u8, '+'), seenChar(seen_bg | seen_obp0));
}

test "a content match names one ROM tile, and refuses two" {
    var rom: [64]u8 = @splat(0);
    rom[16] = 1; // tile at 16 differs from the zero tiles at 0, 32 and 48
    const srcs = [_]Source{
        .{ .entry = 0, .tile = 0, .flat = 0 },
        .{ .entry = 0, .tile = 1, .flat = 16 },
        .{ .entry = 1, .tile = 0, .flat = 32 },
        .{ .entry = 2, .tile = 0, .flat = 16 }, // an alias of the second
    };
    var t: [16]u8 = @splat(0);
    try testing.expectEqual(@as(?u16, null), matchContent(&rom, &srcs, &t));
    t[0] = 1;
    try testing.expectEqual(@as(?u16, 1), matchContent(&rom, &srcs, &t));
}

test "parts chain: initial tiles take the previous end, and aliases share" {
    var rom: [64]u8 = @splat(0);
    for (0..4) |k| rom[k * 16] = @intCast(k + 1);
    const srcs = [_]Source{
        .{ .entry = 0, .tile = 0, .flat = 0 },
        .{ .entry = 0, .tile = 1, .flat = 16 },
        .{ .entry = 0, .tile = 2, .flat = 32 },
        .{ .entry = 1, .tile = 0, .flat = 32 },
    };
    var seen_a: [4]u8 = @splat(0);
    var seen_b: [4]u8 = @splat(0);
    var a: Part = std.mem.zeroes(Part);
    var b: Part = std.mem.zeroes(Part);
    a.seen = &seen_a;
    b.seen = &seen_b;
    a.saves = &.{};
    b.saves = &.{};
    // Part A: tile 0 holds source 1 by content at its start and stays
    // initial; tile 1 is written from source 2.
    @memset(&a.src_end, initial);
    a.vram_start[0] = 2;
    a.src_end[1] = 2;
    a.iseen[0] = seen_bg;
    a.vram_end[0] = 2;
    a.vram_end[16] = 3;
    // Part B: starts as A ended; shows tile 1 while initial, as a sprite.
    @memset(&b.src_end, initial);
    b.vram_start = a.vram_end;
    b.vram_end = a.vram_end;
    b.iseen[1] = seen_obp0;
    seen_b[0] = seen_window;
    const parts = [_]Part{ a, b };
    const c = try combine(testing.allocator, &rom, &srcs, &parts);
    defer testing.allocator.free(c.seen);
    try testing.expectEqual(seen_window, c.seen[0]);
    try testing.expectEqual(seen_bg, c.seen[1]);
    try testing.expectEqual(seen_obp0, c.seen[2]);
    try testing.expectEqual(seen_obp0, c.seen[3]); // the alias of source 2
    try testing.expectEqual(@as(usize, 0), c.unnamed);
    try testing.expectEqual(@as(usize, 0), c.stale);
    try testing.expectEqual(@as(usize, 0), c.seam_tiles);
}
