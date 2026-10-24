//! Colour schemes Step 6: the `schemes` rung. The shipped cart's title with
//! each slot's scheme in cartridge RAM, driven with L, Right, Left, the clear,
//! the reset button and Start, and graded on CGRAM and on the SRAM bytes the
//! cart keeps (`colors.sram_at`).
//!
//! **Each run is its own Mesen2 script**, from SRAM as the run's fixture
//! leaves it: zero, the slots that hold a game given a real record (the magic
//! and the ROM's `initialSaveFile`, the record a new game saves), and the
//! scheme bytes. Nothing is poked once the cart runs: every change goes
//! through the title's own input.
//!
//! **What is graded.** After each step, CGRAM's 16 scheme words are the
//! expected scheme's (`colors.cgramWords`) and, where the step says, SRAM's
//! scheme bytes are what the cart should have kept. And on every run, every
//! CPU write to CGRAM (`$2122`) lands in forced blank or vblank, so a recolour
//! never shows a half-written palette.
//!
//! The reset is Mesen's `emu.reset()`, the console's button: cartridge RAM
//! survives it and WRAM does not, which is what `Reboot` (game over's way back
//! to the title) leaves too. A new Mesen run on the same bytes is a power-on.

const std = @import("std");
const colors = @import("colors.zig");
const save = @import("save.zig");
const offsets = @import("offsets.zig");
const inject = @import("snes_inject.zig");
const romtest = @import("snes_romtest.zig");

pub const Run = enum {
    /// (a) Empty slots: L recolours the title to `mono` and back, and keeps
    /// nothing in SRAM.
    l_press,
    /// (b) Slot 0 a game in `mono`, slot 1 a game in `gbc`, slot 2 empty with
    /// `mono` in its byte: moving the slot recolours to each slot's scheme, and
    /// the empty slot's byte is not read.
    slot_move,
    /// (c) Slots 0 and 1 games, no magic: L on slot 0 keeps `mono` at once,
    /// with the other slots at the default. The reset button, and slot 0 is
    /// still `mono` and slot 1 `gbc`; Start plays in `mono`.
    keep,
    /// (c) The bytes `keep` leaves, from power-on: slot 0 `mono`, slot 1
    /// `gbc`, and Start on slot 1 plays in `gbc`.
    power_on,
    /// (d) Empty slot 0: L shows `mono`, and moving away and back shows the
    /// default. L again and Start plays in `mono` and keeps it; after the
    /// reset the slot, still empty, shows the default.
    empty_slot,
    /// The clear: slot 0 a game in `mono`; the clear empties it and the title
    /// shows the default, and L then keeps nothing.
    cleared,
    /// (e) Slot 0 a game in `mono` behind a bad magic: the title and the game
    /// are the default.
    bad_magic,
    /// (e) A good magic, slot 0 a game with `$FF` and slot 1 one with the
    /// first id past this cart's schemes: both the default, title and game.
    bad_id,
};

pub const Error = error{
    /// The record the fixture puts in a slot is one the title's check
    /// refuses, so the slot would not be a game.
    FixtureNotAGame,
    NoInitialSave,
    MissingSymbol,
};

/// The run's frame budget: two boots, the steps and the waits.
const limit = 3000;
/// Frames between a step's press and its check: the press is published a
/// poll late (`PublishPad`), the title acts on it the frame after, and NMI
/// loads the scheme in the next vblank.
const settle = 6;
/// Frames from Start to the check in play: the load or the new game, and the
/// fade in.
const in_play = 150;

const Key = enum { l, right, left, select };

const Op = union(enum) {
    /// Press a key alone for two polls, then let go.
    press: Key,
    /// The clear: Select to show the option, Down held, Start, Down let go.
    clear,
    /// CGRAM holds this scheme's words.
    expect: colors.Scheme,
    /// SRAM's scheme bytes: null for untouched (zero), else the magic and
    /// these ids.
    sram: ?[save.slots]u8,
    /// The console's reset button, and the title back up.
    reset,
    /// Start, and into play.
    start,
};

const mono: u8 = @intFromEnum(colors.Scheme.mono);
const gbc: u8 = @intFromEnum(colors.Scheme.gbc);
const dflt: u8 = @intFromEnum(colors.default_scheme);

/// What SRAM holds before the boot.
const Fixture = struct {
    /// The slots holding a game.
    games: [save.slots]bool = .{ false, false, false },
    /// The magic, or null for none; and the ids.
    magic: ?[colors.sram_magic.len]u8 = null,
    ids: [save.slots]u8 = .{ 0, 0, 0 },
};

fn fixture(run: Run) Fixture {
    const good = colors.sram_magic;
    return switch (run) {
        .l_press, .empty_slot => .{},
        .slot_move => .{ .games = .{ true, true, false }, .magic = good, .ids = .{ mono, gbc, mono } },
        .keep => .{ .games = .{ true, true, false } },
        .power_on => .{ .games = .{ true, true, false }, .magic = good, .ids = .{ mono, dflt, dflt } },
        .cleared => .{ .games = .{ true, false, false }, .magic = good, .ids = .{ mono, dflt, dflt } },
        .bad_magic => .{ .games = .{ true, false, false }, .magic = .{ good[0], good[1], good[2], good[3] ^ 0x01 }, .ids = .{ mono, mono, mono } },
        .bad_id => .{ .games = .{ true, true, false }, .magic = good, .ids = .{ 0xFF, colors.count, mono } },
    };
}

fn ops(run: Run) []const Op {
    const kept: [save.slots]u8 = .{ mono, dflt, dflt };
    return switch (run) {
        .l_press => &.{
            .{ .expect = .gbc },  .{ .press = .l }, .{ .expect = .mono }, .{ .sram = null },
            .{ .press = .l },     .{ .expect = .gbc },
        },
        .slot_move => &.{
            .{ .expect = .mono }, .{ .press = .right }, .{ .expect = .gbc }, .{ .press = .right },
            .{ .expect = colors.default_scheme }, .{ .press = .left }, .{ .expect = .gbc }, .{ .press = .left },
            .{ .expect = .mono },
        },
        .keep => &.{
            .{ .expect = colors.default_scheme }, .{ .sram = null },        .{ .press = .l },
            .{ .expect = .mono },                 .{ .sram = kept },        .reset,
            .{ .expect = .mono },                 .{ .press = .right },     .{ .expect = .gbc },
            .{ .press = .left },                  .{ .expect = .mono },     .start,
            .{ .expect = .mono },                 .{ .sram = kept },
        },
        .power_on => &.{
            .{ .expect = .mono }, .{ .press = .right }, .{ .expect = .gbc }, .start,
            .{ .expect = .gbc },  .{ .sram = kept },
        },
        .empty_slot => &.{
            .{ .expect = colors.default_scheme }, .{ .press = .l },     .{ .expect = .mono },
            .{ .sram = null },                    .{ .press = .right }, .{ .expect = colors.default_scheme },
            .{ .press = .left },                  .{ .expect = colors.default_scheme }, .{ .press = .l },
            .{ .expect = .mono },                 .start,               .{ .expect = .mono },
            .{ .sram = kept },                    .reset,               .{ .expect = colors.default_scheme },
        },
        .cleared => &.{
            .{ .expect = .mono }, .clear,           .{ .expect = colors.default_scheme }, .{ .press = .l },
            .{ .expect = .mono }, .{ .sram = kept },
        },
        .bad_magic => &.{ .{ .expect = colors.default_scheme }, .start, .{ .expect = colors.default_scheme } },
        .bad_id => &.{
            .{ .expect = colors.default_scheme }, .{ .press = .right }, .{ .expect = colors.default_scheme }, .start,
            .{ .expect = colors.default_scheme },
        },
    };
}

/// A slot that holds a game: the magic and the ROM's new-game record, as the
/// game's own writer leaves a slot it saves.
fn gameRecord(rom: []const u8) ![save.record_len]u8 {
    const e = offsets.find("initial_save") orelse return error.NoInitialSave;
    var r: [save.record_len]u8 = undefined;
    @memcpy(r[0..save.magic_len], &save.magic);
    @memcpy(r[save.magic_len..], rom[e.romOffset()..][0 .. save.record_len - save.magic_len]);
    if (!romtest.slotIsGame(rom, &r)) return error.FixtureNotAGame;
    return r;
}

fn sym(name: []const u8) !u32 {
    return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
}

fn writeWords(w: *std.Io.Writer) !void {
    try w.print("WORDS = {{", .{});
    for (0..colors.count) |id| {
        try w.print(" [{d}] = {{", .{id});
        for (colors.cgramWords(@enumFromInt(id))) |word| try w.print(" {d},", .{word});
        try w.print(" }},", .{});
    }
    try w.print(" }}\n", .{});
}

pub fn code(c: u8) []const u8 {
    return switch (c) {
        0 => "passed",
        1 => "Fatal ran",
        2 => "out of frames: the title never came up, or the game never started",
        4 => "the engine was handed a pose it could not run",
        10 => "CGRAM is not the expected scheme's words",
        11 => "SRAM's scheme bytes are not the ones the cart should have kept",
        12 => "a CGRAM write outside forced blank and vblank",
        255 => "timeout or Lua error",
        else => "unknown",
    };
}

pub fn writeLua(rom: []const u8, run: Run, w: *std.Io.Writer) !void {
    const f = fixture(run);
    const rec = try gameRecord(rom);

    try w.print(
        \\-- Generated by `zig build romtest`. Do not edit.
        \\--
        \\-- The `{s}` run of the `schemes` rung, colour schemes Step 6
        \\-- (`src/scheme_grade.zig`): the shipped cart's title with each slot's
        \\-- colour scheme in SRAM, driven through its own input.
        \\--
        \\-- Exit codes: 0 every step held; 1 Fatal; 2 out of frames; 4 an
        \\-- unrunnable pose; 10 CGRAM not the expected scheme's; 11 SRAM's scheme
        \\-- bytes not the expected; 12 a CGRAM write outside forced blank and
        \\-- vblank. A failure prints what it compared.
        \\
        \\local wram  = emu.memType.snesWorkRam
        \\local sram  = emu.memType.snesSaveRam
        \\local cgram = emu.memType.snesCgRam
        \\local function rd16(addr, kind) return emu.read(addr, kind) | (emu.read(addr + 1, kind) << 8) end
        \\local R = {{ frames = {d}, unhandled = {d}, slot = {d} }}
        \\local LIMIT, SETTLE, IN_PLAY = {d}, {d}, {d}
        \\-- SRAM's scheme bytes: the magic, then an id a slot.
        \\local SCHEME_AT, SLOTS, SLOT_SIZE = {d}, {d}, {d}
        \\-- CGRAM's scheme words, as `LoadPalette` writes them: four runs of
        \\-- four, at these colours.
        \\local RUNS = {{ 0x00, 0x10, 0x80, 0x90 }}
        \\
    , .{
        @tagName(run),
        try sym("VarFrameCount"), try sym("VarUnhandled"), try sym("VarActiveSlot"),
        limit,                    settle,                  in_play,
        colors.sram_at,           save.slots,              save.slot_size,
    });
    try writeWords(w);
    try w.print("MAGIC = {{", .{});
    for (colors.sram_magic) |b| try w.print(" {d},", .{b});
    try w.print(" }}\nRECORD = {{", .{});
    for (rec) |b| try w.print(" {d},", .{b});
    try w.print(" }}\n", .{});

    // The fixture, before the cart runs a cycle.
    try w.print(
        \\
        \\-- Cartridge RAM before the boot: zero, the games, and the scheme bytes.
        \\for i = 0, 0x1FFF do emu.write(i, 0, sram) end
        \\
    , .{});
    for (f.games, 0..) |g, s| {
        if (g) try w.print("for i = 1, #RECORD do emu.write({d} * SLOT_SIZE + i - 1, RECORD[i], sram) end\n", .{s});
    }
    if (f.magic) |m| {
        for (m, 0..) |b, i| try w.print("emu.write(SCHEME_AT + {d}, {d}, sram)\n", .{ i, b });
        for (f.ids, 0..) |id, s| try w.print("emu.write(SCHEME_AT + #MAGIC + {d}, {d}, sram)\n", .{ s, id });
    }

    // The steps.
    try w.print(
        \\
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
        \\local phase, frames, step = 0, 0, 0
        \\PAD, HOLD = {{}}, {{}}
        \\local function frame() coroutine.yield() end
        \\local function wait(n) for i = 1, n do frame() end end
        \\local function press(key)
        \\  PAD = {{ [key] = true }}
        \\  wait(2)
        \\  PAD = {{}}
        \\  wait(SETTLE)
        \\end
        \\local function scheme()
        \\  for id, words in pairs(WORDS) do
        \\    local same = true
        \\    for r = 0, 3 do
        \\      for i = 0, 3 do
        \\        if rd16((RUNS[r + 1] + i) * 2, cgram) ~= words[r * 4 + i + 1] then same = false end
        \\      end
        \\    end
        \\    if same then return id end
        \\  end
        \\  return nil
        \\end
        \\local function expect(id)
        \\  local got = scheme()
        \\  if got ~= id then fail(10, string.format("step %d: CGRAM holds scheme %s, wanted %d (slot %d)", step, tostring(got), id, emu.read(R.slot, wram))) end
        \\end
        \\local function sramIs(ids)
        \\  local want = {{}}
        \\  for i = 1, #MAGIC + SLOTS do want[i] = 0 end
        \\  if ids ~= nil then
        \\    for i = 1, #MAGIC do want[i] = MAGIC[i] end
        \\    for s = 1, SLOTS do want[#MAGIC + s] = ids[s] end
        \\  end
        \\  for i = 1, #want do
        \\    local got = emu.read(SCHEME_AT + i - 1, sram)
        \\    if got ~= want[i] then fail(11, string.format("step %d: SRAM scheme byte %d is %02x, wanted %02x", step, i - 1, got, want[i])) end
        \\  end
        \\end
        \\-- Back to the title: the console's reset, and the title's first frame.
        \\local function reset()
        \\  emu.reset()
        \\  phase = 0
        \\  frame()
        \\end
        \\-- Start alone, and into play: the frame counter stops while the title
        \\-- hands over and runs again in the game.
        \\local function start()
        \\  PAD = {{ start = true }}
        \\  wait(2)
        \\  PAD = {{}}
        \\  wait(IN_PLAY)
        \\end
        \\-- The clear, as a player does it: Select shows the option, Down held
        \\-- selects it, and Start alone on its edge takes it.
        \\local function clear()
        \\  press("select")
        \\  HOLD = {{ down = true }}
        \\  wait(4)
        \\  PAD = {{ start = true }}
        \\  wait(2)
        \\  PAD = {{}}
        \\  wait(2)
        \\  HOLD = {{}}
        \\  wait(SETTLE)
        \\end
        \\
        \\local function main()
        \\  -- A few frames of the title before the first look.
        \\  wait(SETTLE)
        \\
    , .{});
    for (ops(run), 1..) |op, i| {
        try w.print("  step = {d}; ", .{i});
        switch (op) {
            .press => |k| try w.print("press(\"{s}\")\n", .{@tagName(k)}),
            .clear => try w.print("clear()\n", .{}),
            .expect => |s| try w.print("expect({d})\n", .{@intFromEnum(s)}),
            .sram => |ids| if (ids) |v| try w.print("sramIs({{ {d}, {d}, {d} }})\n", .{ v[0], v[1], v[2] }) else try w.print("sramIs(nil)\n", .{}),
            .reset => try w.print("reset(); wait(SETTLE)\n", .{}),
            .start => try w.print("start()\n", .{}),
        }
    }
    try w.print(
        \\  print("{s}: every step held")
        \\  emu.stop(0)
        \\end
        \\
        \\-- Every CPU write to CGRAM, in forced blank or vblank (line 225 on).
        \\emu.addMemoryCallback(function()
        \\  if stopped then return end
        \\  local st = emu.getState()
        \\  if not st["ppu.forcedBlank"] and st["ppu.scanline"] < 225 then
        \\    fail(12, string.format("step %d: a CGRAM write on line %d, the screen on", step, st["ppu.scanline"]))
        \\  end
        \\end, emu.callbackType.write, 0x2122, 0x2122, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\local co = coroutine.create(main)
        \\emu.addEventCallback(function()
        \\  if stopped then return end
        \\  frames = frames + 1
        \\  if rd16(0, cgram) == 0x7C1F then fail(1, "Fatal") end
        \\  if emu.read(R.unhandled, wram) ~= 0 then fail(4, "unhandled pose " .. emu.read(R.unhandled, wram)) end
        \\  if frames > LIMIT then fail(2, "step " .. step .. " at frame " .. frames) end
        \\  -- The title's counter moves once it is up.
        \\  if phase == 0 then
        \\    if rd16(R.frames, wram) == 0 then return end
        \\    phase = 1
        \\  end
        \\  if coroutine.status(co) == "dead" then return end
        \\  local ok, err = coroutine.resume(co)
        \\  if not ok then fail(2, "script: " .. tostring(err)) end
        \\end, emu.eventType.endFrame)
        \\
        \\emu.addEventCallback(function()
        \\  local p = {{}}
        \\  if phase == 1 then
        \\    for k, v in pairs(HOLD) do p[k] = v end
        \\    for k, v in pairs(PAD) do p[k] = v end
        \\  end
        \\  emu.setInput(p, 0)
        \\end, emu.eventType.inputPolled)
        \\
    , .{@tagName(run)});
}

test "every run ends on a check, and the fixture's record is a game" {
    for (std.enums.values(Run)) |r| {
        const o = ops(r);
        try std.testing.expect(o.len > 0);
        try std.testing.expect(o[o.len - 1] == .expect or o[o.len - 1] == .sram);
    }
    const gpa = std.testing.allocator;
    const rom = try @import("testrom").load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    _ = try gameRecord(rom);
}
