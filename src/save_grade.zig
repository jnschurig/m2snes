//! 1.0 Step 18e: a save round trip at every save station, through the debug
//! menu's own input on the `--debug` cart.
//!
//! **The trip.** From a new game: FULL LOADOUT, the clock moved, a Metroid of
//! another bank killed from METROIDS, then the warp to the station. With its
//! bank loaded, a Metroid of that bank killed and one of its item orbs marked
//! taken on FLAGS, so both the live flags and the saved ones are in play. Then
//! Start on the station, the reset button, the title's Start, and the load.
//!
//! **What it is graded against.**
//! - The loaded state the record keeps, `$D808`-`$D814`, in the record and
//!   again after the load: our Game Boy's, running the station's chain by door
//!   index from the new game (`warp_grade.references`). This is what a station
//!   inherits from the doors that led to it, and what the load must put back.
//! - The rest of the record: the live variables on the frame Start is
//!   pressed, as B7's `round trip` grades it (the writer itself is 0b Step
//!   15a's, graded there); and after the load, the record, as B7's `load`.
//! - The spawn flags: the three marked dead in the record's window, the
//!   loaded buffer the record's, and the orb not loaded by a warp to it.
//! - The map over the camera's view after the load: the one she saved in,
//!   which the `warp` rung grades against our Game Boy on arrival.
//!
//! The reset is Mesen's `emu.reset()`, the console's button: cartridge RAM
//! survives it and nothing else does. The Game Boy's soft reset (00:$02E1) is
//! not ported (`engine/main.asm`, B7 Step 15c).

const std = @import("std");
const warp = @import("warp.zig");
const warp_grade = @import("warp_grade.zig");
const debug_tables = @import("debug_tables.zig");
const save = @import("save.zig");

/// The CLOCK page's root row.
const clock_row = 3;
/// Cartridge RAM: slot 0's record, and its spawn flags (`!SRAM_SPAWN`).
const spawn_sram: u16 = 0x1000;
const spawn_len: u16 = 0x40 * 7;
/// The first spawn number of the saved half, which the windows hold.
const saved_first: u8 = debug_tables.saved_first;
/// The run's frame budget: two boots, the menu's presses and the waits.
const limit = 9000;

pub const Error = error{ NoMetroidElsewhere, NoItem };

/// The stations on the WARP page, as indices into `sorted`.
pub fn stations(a: std.mem.Allocator, sorted: []const warp.Entry) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (sorted, 0..) |e, i| if (e.dest.kind == .station) try out.append(a, i);
    return out.toOwnedSlice(a);
}

/// What one station's run marks: METROIDS rows (one of another bank, one of
/// the station's when it has any) and an item orb of the station's bank,
/// by its FLAGS row and its ITEMS entry.
pub const Marks = struct {
    other: u8,
    here: ?u8,
    flag: u8,
    item: usize,
};

pub fn marks(a: std.mem.Allocator, rom: []const u8, sorted: []const warp.Entry, station: usize) !Marks {
    const bank = sorted[station].dest.at.bank;
    const mets = try debug_tables.metroidsBlob(a, rom);
    const flags = try debug_tables.flagsBlob(a, rom);
    var other: ?u8 = null;
    var here: ?u8 = null;
    // The last row is the Queen's, which has no spawn record.
    for (0..mets[0] - 1) |i| {
        const b = mets[1 + i * debug_tables.entry_bytes];
        if (b != bank and other == null) other = @intCast(i);
        if (b == bank and here == null) here = @intCast(i);
    }
    // The first orb FLAGS lists, the station's bank's when it has one: a
    // refill's record is in the half every room entry clears, and is not.
    var pass: u2 = 0;
    while (pass < 2) : (pass += 1) for (sorted, 0..) |e, i| {
        if (e.dest.kind != .item or (pass == 0 and e.dest.at.bank != bank)) continue;
        const rec = e.dest.record.?;
        const flag = warp_grade.blobRow(flags, rec.bank, rec.number) orelse continue;
        return .{
            .other = other orelse return Error.NoMetroidElsewhere,
            .here = here,
            .flag = flag,
            .item = i,
        };
    };
    return Error.NoItem;
}

pub fn code(c: u8) []const u8 {
    return switch (c) {
        50 => "she is not on the station after the warp: no contact",
        51 => "the loaded state ($D808-$D814) is not the Game Boy's, before the save or in the record",
        52 => "Start on the station wrote no record",
        53 => "the record is not what she held when Start was pressed",
        54 => "a Metroid killed or an orb taken is not dead in the record's spawn flags",
        55 => "after the load, she is not in the record",
        56 => "after the load, the loaded state ($D808-$D814) is not the Game Boy's",
        57 => "after the load, the map over the camera's view is not the one she saved in",
        58 => "after the load, the spawn flags are not the record's",
        59 => "after the load, a warp to the taken orb loaded it",
        else => warp_grade.scenarioCode(c),
    };
}

pub fn writeLua(a: std.mem.Allocator, rom: []const u8, sorted: []const warp.Entry, station: usize, ref: warp_grade.Ref, w: *std.Io.Writer) !void {
    const e = sorted[station];
    const m = try marks(a, rom, sorted, station);
    const mets = try debug_tables.metroidsBlob(a, rom);
    const flags = try debug_tables.flagsBlob(a, rom);
    const sym = warp_grade.sym;

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The `saves` rung, 1.0 Step 18e: the station at {X}:{X:0>2}. Saved in
        \\-- with a Metroid of another bank and one of its own killed and an orb
        \\-- taken, then the reset button and the load (`src/save_grade.zig`).
        \\--
        \\-- Exit codes: 0 held; 1 Fatal; 2 no play, or out of frames; 3 A did not
        \\-- warp; 4 an unrunnable pose; 50 no contact; 51 the loaded state before
        \\-- the save or in the record; 52 no record; 53 the record is not what
        \\-- she held; 54 a mark not dead in the record; 55 not in the record after
        \\-- the load; 56 the loaded state after it; 57 the map over the view
        \\-- after it; 58 the spawn flags after it; 59 the taken orb loaded.
        \\
    , .{ e.dest.at.bank, e.dest.at.cell });
    try warp_grade.writeMenuPrelude(rom, sorted, limit, w);

    try w.print(
        \\
        \\local sram = emu.memType.snesSaveRam
        \\local function sr16(i) return emu.read(i, sram) | (emu.read(i + 1, sram) << 8) end
        \\local S = {{ camy = {d}, camx = {d}, items = {d}, beam = {d}, tanks = {d}, health = {d},
        \\  maxmiss = {d}, curmiss = {d}, facing = {d}, acid = {d}, spike = {d}, shown = {d},
        \\  song = {d}, minutes = {d}, hours = {d}, contact = {d}, tilemap = {d}, saved = {d} }}
        \\local VIEW_ROWS, VIEW_COLS = {d}, {d}
        \\local SPAWN, SPAWN_LEN, SAVED_FIRST = {d}, {d}, {d}
        \\local MAGIC = {{
    , .{
        try sym("VarCamY"),      try sym("VarCamX"),      try sym("VarItems"),
        try sym("VarBeam"),      try sym("VarTanks"),     try sym("VarHealthLo"),
        try sym("VarMaxMissLo"), try sym("VarCurMissLo"), try sym("VarFacing"),
        try sym("VarAcidDmg"),   try sym("VarSpikeDmg"),  try sym("VarMetDisp"),
        try sym("VarSong"),      try sym("VarIgtMinutes"), try sym("VarIgtHours"),
        try sym("VarSaveContact"), try sym("VarTilemapBuf"), try sym("VarSpawnSaveBuf"),
        warp_grade.view_rows,    warp_grade.view_cols,
        spawn_sram,              spawn_len,               saved_first,
    });
    for (save.magic, 0..) |b, i| try w.print("{s}{d}", .{ if (i == 0) " " else ", ", b });
    try w.print(" }}\nlocal REF = {{", .{});
    for (ref.block, 0..) |b, i| try w.print("{s}{d}", .{ if (i == 0) " " else ", ", b });
    const item_rec = sorted[m.item].dest.record.?;
    const other = mets[1 + @as(usize, m.other) * debug_tables.entry_bytes ..];
    // The marked records, bank and number: the Metroid elsewhere, the orb, and
    // the station's own Metroid when its bank has one.
    try w.print(" }}\nlocal MARKED = {{ {{ {d}, {d}, \"Metroid {X}:{X:0>2}\" }}, {{ {d}, {d}, \"orb {X}:{X:0>2}\" }}", .{
        other[0], other[2], other[0], other[1], item_rec.bank, item_rec.number, item_rec.bank, item_rec.cell,
    });
    if (m.here) |h| {
        const here = mets[1 + @as(usize, h) * debug_tables.entry_bytes ..];
        try w.print(", {{ {d}, {d}, \"Metroid {X}:{X:0>2}\" }}", .{ here[0], here[2], here[0], here[1] });
    }
    try w.print(" }}\n", .{});
    try w.print(
        \\local BANK, ST_ROW, ITEM_ROW, ITEM_NUM, SY, SX = {d}, {d}, {d}, {d}, {d}, {d}
        \\local OTHER, HERE, FLAG_ROW, METS_N, FLAGS_N = {d}, {s}, {d}, {d}, {d}
        \\local MET_ROOT, FLAGS_ROOT, CLOCK_ROOT = {d}, {d}, {d}
        \\
    , .{
        e.dest.at.bank,                              debug_tables.warpRow(sorted, station)[1],
        debug_tables.warpRow(sorted, m.item)[1],     item_rec.number,
        e.samus_y,                                   e.samus_x,
        m.other,                                     if (m.here) |h| try std.fmt.allocPrint(a, "{d}", .{h}) else "nil",
        m.flag,                                      mets[0],
        flags[0],                                    warp_grade.metroids_row,
        warp_grade.flags_row,                        clock_row,
    });

    try w.print(
        \\
        \\-- What the record keeps, as the live variables hold it, and as slot 0's
        \\-- record does (`save.fields`: the magic, then position, camera, the
        \\-- block at $10, and the rest one byte or word at a time).
        \\local FIELDS = {{ "sy", "sx", "camy", "camx", "items", "beam", "tanks", "health", "maxmiss",
        \\  "curmiss", "facing", "acid", "spike", "real", "song", "minutes", "hours", "shown" }}
        \\local function live()
        \\  return {{ sy = rd16(R.sy), sx = rd16(R.sx), camy = rd16(S.camy), camx = rd16(S.camx),
        \\    items = emu.read(S.items, wram), beam = emu.read(S.beam, wram), tanks = emu.read(S.tanks, wram),
        \\    health = rd16(S.health), maxmiss = rd16(S.maxmiss), curmiss = rd16(S.curmiss),
        \\    facing = emu.read(S.facing, wram), acid = emu.read(S.acid, wram), spike = emu.read(S.spike, wram),
        \\    real = emu.read(R.real, wram), song = emu.read(S.song, wram), minutes = emu.read(S.minutes, wram),
        \\    hours = emu.read(S.hours, wram), shown = emu.read(S.shown, wram) }}
        \\end
        \\local function record()
        \\  return {{ sy = sr16(0x08), sx = sr16(0x0A), camy = sr16(0x0C), camx = sr16(0x0E),
        \\    items = emu.read(0x1D, sram), beam = emu.read(0x1E, sram), tanks = emu.read(0x1F, sram),
        \\    health = sr16(0x20), maxmiss = sr16(0x22), curmiss = sr16(0x24), facing = emu.read(0x26, sram),
        \\    acid = emu.read(0x27, sram), spike = emu.read(0x28, sram), real = emu.read(0x29, sram),
        \\    song = emu.read(0x2A, sram), minutes = emu.read(0x2B, sram), hours = emu.read(0x2C, sram),
        \\    shown = emu.read(0x2D, sram) }}
        \\end
        \\local function differs(got, want, what, c)
        \\  for _, f in ipairs(FIELDS) do
        \\    if got[f] ~= want[f] then fail(c, string.format("%s: %s %04x, %04x wanted", what, f, got[f], want[f])) end
        \\  end
        \\end
        \\local function block(read, what, c)
        \\  for i = 1, #REF do
        \\    if read(i - 1) ~= REF[i] then
        \\      fail(c, string.format("%s: $D8%02X %02x, the Game Boy's %02x", what, 7 + i, read(i - 1), REF[i]))
        \\    end
        \\  end
        \\end
        \\-- The map over the camera's view, slot for slot, as `warp_grade.viewSlot`.
        \\local function view()
        \\  local top, left = (rd16(S.camy) - 0x48) & 0xFFF, (rd16(S.camx) - 0x50) & 0xFFF
        \\  local t = {{}}
        \\  for r = 0, VIEW_ROWS - 1 do
        \\    for c = 0, VIEW_COLS - 1 do
        \\      local slot = ((((top >> 3) + r) & 31) * 32) + (((left >> 3) + c) & 31)
        \\      t[#t + 1] = emu.read(S.tilemap + slot * 2, wram)
        \\    end
        \\  end
        \\  return t
        \\end
        \\local function mark(root, row, n) page(root); rows(0, row, n); press("a"); press("b"); press("b") end
        \\-- Back onto the pad when a hit has taken her off it, as a player would
        \\-- walk back: `$F:$04`'s enemy beside it hits her on the frame she
        \\-- arrives. Toward its middle, jumping (B, as the crawl does) while she
        \\-- is below it, until the contact has held for a few frames.
        \\local function toPad()
        \\  local held = 0
        \\  for f = 1, 900 do
        \\    if emu.read(S.contact, wram) == 0xFF then held = held + 1 else held = 0 end
        \\    if held >= 4 then PAD = {{}}; return end
        \\    local x, y = rd16(R.sx), rd16(R.sy)
        \\    PAD = {{ right = x < SX - 1, left = x > SX + 1, b = y > SY + 4 and f % 40 < 30 }}
        \\    if held > 0 then PAD = {{}} end
        \\    frame()
        \\  end
        \\  PAD = {{}}
        \\end
        \\
        \\local function main()
        \\  loadout()
        \\  -- The clock off the new game's: hours up two, minutes down one.
        \\  page(CLOCK_ROOT); press("right"); press("right"); press("down"); press("left"); press("b"); press("b")
        \\  -- A Metroid of another bank, before the warp.
        \\  mark(MET_ROOT, OTHER, METS_N)
        \\  warp(0, ST_ROW)
        \\  wait(10)
        \\  -- With the station's bank loaded: one of its Metroids, and an orb.
        \\  if HERE ~= nil then mark(MET_ROOT, HERE, METS_N) end
        \\  mark(FLAGS_ROOT, FLAG_ROW, FLAGS_N)
        \\  wait(10)
        \\  toPad()
        \\  if emu.read(S.contact, wram) ~= 0xFF then
        \\    fail(50, string.format("at %04x,%04x, contact %02x", rd16(R.sy), rd16(R.sx), emu.read(S.contact, wram)))
        \\  end
        \\  block(function(i) return emu.read(R.block + i, wram) end, "before the save", 51)
        \\
        \\  -- Start on the station: the save is the next frame's.
        \\  local held, map = live(), view()
        \\  press("start")
        \\  wait(20)
        \\  for i = 1, #MAGIC do
        \\    if emu.read(i - 1, sram) ~= MAGIC[i] then fail(52, "slot 0's magic byte " .. (i - 1)) end
        \\  end
        \\  block(function(i) return emu.read(0x10 + i, sram) end, "the record", 51)
        \\  local rec = record()
        \\  differs(rec, held, "the record", 53)
        \\  for _, k in ipairs(MARKED) do
        \\    local f = emu.read(SPAWN + (k[1] - 9) * 0x40 + k[2] - SAVED_FIRST, sram)
        \\    if f ~= DEAD then fail(54, string.format("%s: %02x in the record", k[3], f)) end
        \\  end
        \\  local flags = {{}}
        \\  for i = 0, SPAWN_LEN - 1 do flags[i] = emu.read(SPAWN + i, sram) end
        \\
        \\  reboot()
        \\  differs(live(), rec, "after the load", 55)
        \\  block(function(i) return emu.read(R.block + i, wram) end, "after the load", 56)
        \\  local now = view()
        \\  for i = 1, #map do
        \\    if now[i] ~= map[i] then
        \\      fail(57, string.format("view tile %d (row %d col %d): %02x, %02x when she saved", i - 1,
        \\        (i - 1) // VIEW_COLS, (i - 1) % VIEW_COLS, now[i], map[i]))
        \\    end
        \\  end
        \\  for i = 0, SPAWN_LEN - 1 do
        \\    if emu.read(S.saved + i, wram) ~= flags[i] then
        \\      fail(58, string.format("saved flag %X:%02X %02x, the record's %02x", 9 + i // 0x40, SAVED_FIRST + i % 0x40,
        \\        emu.read(S.saved + i, wram), flags[i]))
        \\    end
        \\  end
        \\  for _, k in ipairs(MARKED) do
        \\    if k[1] == BANK and emu.read(R.spawn + k[2], wram) ~= DEAD then
        \\      fail(58, string.format("%s: live flag %02x", k[3], emu.read(R.spawn + k[2], wram)))
        \\    end
        \\  end
        \\
        \\  -- And the orb stays taken.
        \\  warp(1, ITEM_ROW)
        \\  wait(10)
        \\  if slotOf(ITEM_NUM) ~= nil then fail(59, "the orb is in slot " .. slotOf(ITEM_NUM)) end
        \\  print(string.format("saved at %X:%02X and loaded: the record, its loaded state, its flags and its view", BANK, {d}))
        \\  emu.stop(0)
        \\end
        \\
    , .{e.dest.at.cell});
    try warp_grade.writeRunner(w);
}

/// The rung's fault: the load's search for the record's metatile table taken
/// as found at the first (`beq` to `bra`), so a load draws with table 0 what
/// the record says another. Every station's view differs (57); the gate runs
/// it on the first.
pub const fault = struct {
    pub const label = "LoadGameGraphics_metaTest";
    pub const patch: []const u8 = &.{0x80};
    pub const want: u8 = 57;
};
