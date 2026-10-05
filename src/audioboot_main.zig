//! `zig build audioboot` — how the shipped cart's sound comes up, measured in
//! Mesen2 (metroid2-audio Step 16a).
//!
//! Two boots of the cart `zig build rom` writes, each stopped at its first pass
//! (the first `AudioFrame`, which is the title's loop on the shipped cart):
//!
//!   - **sound**: the ARAM image goes up through the IPL. Reports the frames the
//!     upload took (`!AudUpFrames`, the figure the debug readout shows) and fails
//!     unless the shim came up.
//!   - **no sound**: every read of the APU ports returns 0, so the boot ROM's
//!     $BBAA never arrives. Every wait is bounded, so the cart has to reach its
//!     first pass anyway, with `!AudState` saying the sound is down.
//!
//!   - **room**: the shipped cart, Start pressed at the title, run past the
//!     appearance sequence. The room's song has to come up: `!Song` seeded from
//!     `BootRoomSong` ($04, the main caves), a request for it out of 00:$0EAF,
//!     and the reply reporting it playing. Nothing else covers that site --
//!     `audioparity` grades handover stretches, which have no appearance -- and
//!     its absence is what left a new game silent (`docs/bug_tracker.md`,
//!     2026-09-22).
//!
//!   - **beep**: the cart `snes boot` grades (it boots in play), with health
//!     forced below $50 and back. The low-health beep's clear has to go out
//!     once, as on the Game Boy, where a port reading only the reply -- two
//!     ticks behind (`docs/audio_protocol.md`) -- sends it three times; and a
//!     beep asked for one frame before health recovers has to be cleared, where
//!     that port never clears it.
//!
//! Mesen2 swallows `emu.log` in testrunner mode, so the numbers come back
//! through save RAM, as `audio_parity`'s stream does.

const std = @import("std");
const build_options = @import("build_options");
const convert = @import("snes_convert.zig");
const screen = @import("snes_screen.zig");
const inject = @import("snes_inject.zig");
const trace = @import("snes_trace.zig");

const stem = "audioboot";
const cart_name = trace.out_dir ++ "/" ++ stem ++ ".sfc";
const lua_name = trace.out_dir ++ "/" ++ stem ++ ".lua";
/// Past the 8 KiB the game's own save file uses.
const report_at: usize = 0x2000;
const marker: u8 = 0xA5;
/// Frames either boot may take to reach its first pass. The upload is ~60.
const watchdog_frames = 600;

const Boot = struct { state: u8, up_frames: u16, frames: u16 };

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (build_options.rom_path.len == 0 or build_options.mesen_path.len == 0) {
        try out.print("audioboot: skipped, needs M2_ROM and MESEN (see docs/setup.md)\n", .{});
        return 0;
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, build_options.rom_path, gpa, .limited(1 << 20));
    var set = try convert.run(gpa, rom);
    defer set.deinit();
    var aram_bytes: usize = 0;
    for (set.aram) |b| aram_bytes += b.bytes.len - 2;

    // The shipped cart, as `builder.build` builds it.
    const boot = try screen.newGameBoot(gpa, rom);
    var diag: inject.Diagnosis = .{};
    var cart = try inject.build(gpa, set, boot, &diag);
    defer cart.deinit();
    const stamped = try gpa.dupe(u8, cart.bytes);
    try trace.stampSram(stamped);

    const running = inject.symbol("ConstAudRunning") orelse return error.MissingSymbol;
    const down = inject.symbol("ConstAudDown") orelse return error.MissingSymbol;
    const home = init.environ_map.get("HOME") orelse "";

    const sound = try run(gpa, io, stamped, false, home);
    const silent = try run(gpa, io, stamped, true, home);

    try out.print("audioboot: ARAM image {d} bytes in {d} blocks\n", .{ aram_bytes, set.aram.len });
    try out.print("  sound     state {d}, upload {d} frames ({d} ms), first pass at frame {d}\n", .{
        sound.state, sound.up_frames, @as(u32, sound.up_frames) * 1000 / 60, sound.frames,
    });
    try out.print("  no sound  state {d}, first pass at frame {d}\n", .{ silent.state, silent.frames });
    var ok = true;
    if (sound.state != running) {
        try out.print("FAIL the shim did not come up (state {d}, want {d})\n", .{ sound.state, running });
        ok = false;
    }
    if (silent.state != down) {
        try out.print("FAIL with the ports silent the cart says state {d}, want {d}\n", .{ silent.state, down });
        ok = false;
    }
    if (ok) try out.print("ok   both boots reach their first pass, and the readout's state says which one had sound\n", .{});

    // The room's song, on the shipped cart: the one check of 00:$0EAF.
    const room = try runRoom(gpa, io, stamped, home);
    try out.print("  room      !Song ${X:0>2}, requested ${X:0>2}, playing ${X:0>2} from pass {d}\n", .{
        room.song, room.requested, room.playing, room.at,
    });
    if (room.song != room_song or room.requested != room_song or room.playing != room_song or room.at == 0) {
        try out.print("FAIL the room's song never came up: want ${X:0>2} seeded, requested and playing\n", .{room_song});
        ok = false;
    } else try out.print("ok   a new game asks for the room's song and the engine plays it\n", .{});

    // The beep, on a cart that boots in play.
    const play_boot = try screen.chooseBoot(gpa, rom);
    var play = try inject.build(gpa, set, play_boot, &diag);
    defer play.deinit();
    const play_stamped = try gpa.dupe(u8, play.bytes);
    try trace.stampSram(play_stamped);
    const beep = try runBeep(gpa, io, play_stamped, home);
    try out.print("  beep      recovered: {d} clear(s); one frame low: {d} beep(s) asked, {d} clear(s)\n", .{
        beep.clears_recovered, beep.starts_blip, beep.clears_blip,
    });
    if (beep.clears_recovered != 1 or beep.starts_blip != 1 or beep.clears_blip != 1) {
        try out.print("FAIL the beep's clear, want exactly one each time and one beep asked\n", .{});
        ok = false;
    } else try out.print("ok   the beep is cleared once, as on the Game Boy, and a one-frame beep is cleared\n", .{});
    return if (ok) 0 else 1;
}

/// `initialSaveFile`'s "Song for room": the main caves. Stated here rather than
/// read from the ROM because the check is that the cart carries *this* song, and
/// a test that derived it from the same place the cart does could not fail.
const room_song: u8 = 0x04;

const Room = struct {
    /// `!Song` once `InitState` has seeded it.
    song: u8,
    /// The last song id the cart requested through `AudioPut`.
    requested: u8,
    /// `songPlaying` in the reply at the end.
    playing: u8,
    /// The pass the reply first reported the room's song. Zero means never.
    at: u16,
};

/// Start held at the title (in frames: the upload alone is ~60, and the title is
/// its own loop before `MainLoop`), then passes enough for the appearance's
/// 320-frame countdown to run out and 00:$0EAF's request to go out and come
/// back in a reply.
const room_start = 90;
const room_end = 480;

fn runRoom(gpa: std.mem.Allocator, io: std.Io, cart: []const u8, home: []const u8) !Room {
    const main_loop = inject.symbol("MainLoop") orelse return error.MissingSymbol;
    const put = inject.symbol("AudioPut") orelse return error.MissingSymbol;
    const val = inject.symbol("VarAudVal") orelse return error.MissingSymbol;
    const song = inject.symbol("VarSong") orelse return error.MissingSymbol;
    const reply = inject.symbol("VarAudReply") orelse return error.MissingSymbol;
    const req_song = inject.symbol("ConstReqSong") orelse return error.MissingSymbol;

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, trace.out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".sfc", .data = cart });
    var lua: std.Io.Writer.Allocating = .init(gpa);
    defer lua.deinit();
    try lua.writer.print(
        \\-- Generated by src/audioboot_main.zig. Do not edit.
        \\local sram = emu.memType.snesSaveRam
        \\local wram = emu.memType.snesWorkRam
        \\local MAIN, PUT, VAL = 0x{X:0>6}, 0x{X:0>6}, 0x{X:0>4}
        \\local SONG, REPLY, REQ = 0x{X:0>4}, 0x{X:0>4}, {d}
        \\local START, END = {d}, {d}
        \\local BASE, MARKER, WATCHDOG = {d}, {d}, {d}
        \\local passes, requested, at, frames = 0, 0, 0, 0
        \\-- Start, held for a few frames at the title: the port's title takes
        \\-- Start and nothing else, and on a Mesen2 run the save RAM is blank,
        \\-- so it finds no game in slot 0 and a new game is what begins.
        \\--
        \\-- Counted in frames and not in passes: `TitleScreen` is its own loop,
        \\-- reached before `MainLoop` ever runs, so a press waiting for a pass
        \\-- waits forever and the run times out. It did.
        \\emu.addEventCallback(function()
        \\  if frames >= START and frames < START + 8 then emu.setInput({{ start = true }}, 0) end
        \\end, emu.eventType.inputPolled)
        \\emu.addMemoryCallback(function()
        \\  passes = passes + 1
        \\  -- `songPlaying` is the reply's seventh byte, and the reply is
        \\  -- committed whole at the top of the pass, so reading it here reads a
        \\  -- matched set rather than a value mid-flight.
        \\  if at == 0 and emu.read(REPLY + 6, wram) == {d} then at = passes end
        \\  if passes == END then
        \\    emu.write(BASE, MARKER, sram)
        \\    emu.write(BASE + 1, emu.read(SONG, wram), sram)
        \\    emu.write(BASE + 2, requested, sram)
        \\    emu.write(BASE + 3, emu.read(REPLY + 6, wram), sram)
        \\    emu.write(BASE + 4, at & 0xFF, sram)
        \\    emu.write(BASE + 5, (at >> 8) & 0xFF, sram)
        \\    emu.stop(0)
        \\  end
        \\end, emu.callbackType.exec, MAIN, MAIN, emu.cpuType.snes, emu.memType.snesMemory)
        \\emu.addMemoryCallback(function()
        \\  if (emu.getState()["cpu.a"] & 0xFF) == REQ then requested = emu.read(VAL, wram) end
        \\end, emu.callbackType.exec, PUT, PUT, emu.cpuType.snes, emu.memType.snesMemory)
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  if frames > END + WATCHDOG then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{
        main_loop, put, @as(u16, @truncate(val)),
        @as(u16, @truncate(song)), @as(u16, @truncate(reply)), @as(u8, @truncate(req_song)),
        room_start, room_end,
        report_at, marker, watchdog_frames,
        room_song,
    });
    try dir.writeFile(io, .{ .sub_path = stem ++ ".lua", .data = lua.written() });

    const srm = try trace.savePath(gpa, io, home, stem);
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, cart_name, "--testrunner", lua_name, "--timeout=60" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;
    if (code == 1) return error.CartNeverReachedAFrame;
    if (code != 0) return error.CartDidNotFinish;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, srm, gpa, .limited(trace.sram_bytes * 2));
    if (bytes.len < report_at + 6 or bytes[report_at] != marker) return error.NoReport;
    return .{
        .song = bytes[report_at + 1],
        .requested = bytes[report_at + 2],
        .playing = bytes[report_at + 3],
        .at = @as(u16, bytes[report_at + 4]) | (@as(u16, bytes[report_at + 5]) << 8),
    };
}

const Beep = struct { clears_recovered: u8, starts_blip: u8, clears_blip: u8 };

/// Passes: health forced to $30 at `low`, back to $99 at `high`, and the clears
/// counted up to `blip`; then $20 at `blip` alone (a value `PrevHealthLo` does
/// not hold, so the beep is asked for again) and $99 the pass after.
const beep_low = 60;
const beep_high = 90;
const beep_blip = 150;
const beep_end = 200;

fn runBeep(gpa: std.mem.Allocator, io: std.Io, cart: []const u8, home: []const u8) !Beep {
    const main_loop = inject.symbol("MainLoop") orelse return error.MissingSymbol;
    const put = inject.symbol("AudioPut") orelse return error.MissingSymbol;
    const val = inject.symbol("VarAudVal") orelse return error.MissingSymbol;
    const hlo = inject.symbol("VarHealthLo") orelse return error.MissingSymbol;

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, trace.out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".sfc", .data = cart });
    var lua: std.Io.Writer.Allocating = .init(gpa);
    defer lua.deinit();
    try lua.writer.print(
        \\-- Generated by src/audioboot_main.zig. Do not edit.
        \\local sram = emu.memType.snesSaveRam
        \\local wram = emu.memType.snesWorkRam
        \\local MAIN, PUT, VAL, HLO = 0x{X:0>6}, 0x{X:0>6}, 0x{X:0>4}, 0x{X:0>4}
        \\local LOW, HIGH, BLIP, END = {d}, {d}, {d}, {d}
        \\local BASE, MARKER, WAVE, WATCHDOG = {d}, {d}, {d}, {d}
        \\local passes, recovered, starts, blip, frames = 0, 0, 0, 0, 0
        \\local function health(v) emu.write(HLO, v, wram); emu.write(HLO + 1, 0, wram) end
        \\emu.addMemoryCallback(function()
        \\  passes = passes + 1
        \\  if passes == LOW then health(0x30) end
        \\  if passes == HIGH then health(0x99) end
        \\  if passes == BLIP then health(0x20) end
        \\  if passes == BLIP + 1 then health(0x99) end
        \\  if passes == END then
        \\    emu.write(BASE, MARKER, sram)
        \\    emu.write(BASE + 1, recovered, sram)
        \\    emu.write(BASE + 2, starts, sram)
        \\    emu.write(BASE + 3, blip, sram)
        \\    emu.stop(0)
        \\  end
        \\end, emu.callbackType.exec, MAIN, MAIN, emu.cpuType.snes, emu.memType.snesMemory)
        \\emu.addMemoryCallback(function()
        \\  if (emu.getState()["cpu.a"] & 0xFF) ~= WAVE then return end
        \\  local v = emu.read(VAL, wram)
        \\  if v == 0xFF then
        \\    if passes >= HIGH and passes < BLIP then recovered = recovered + 1 end
        \\    if passes >= BLIP then blip = blip + 1 end
        \\  elseif passes >= BLIP then
        \\    starts = starts + 1
        \\  end
        \\end, emu.callbackType.exec, PUT, PUT, emu.cpuType.snes, emu.memType.snesMemory)
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  if frames > END + WATCHDOG then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{
        main_loop,                            put,  @as(u16, @truncate(val)), @as(u16, @truncate(hlo)),
        beep_low,                             beep_high, beep_blip,           beep_end,
        report_at,                            marker,    @import("audio_req.zig").slotByName("sfxRequest_wave").?,
        watchdog_frames,
    });
    try dir.writeFile(io, .{ .sub_path = stem ++ ".lua", .data = lua.written() });

    const srm = try trace.savePath(gpa, io, home, stem);
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, cart_name, "--testrunner", lua_name, "--timeout=60" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;
    if (code == 1) return error.CartNeverReachedAFrame;
    if (code != 0) return error.CartDidNotFinish;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, srm, gpa, .limited(trace.sram_bytes * 2));
    if (bytes.len < report_at + 4 or bytes[report_at] != marker) return error.NoReport;
    return .{ .clears_recovered = bytes[report_at + 1], .starts_blip = bytes[report_at + 2], .clears_blip = bytes[report_at + 3] };
}

fn run(gpa: std.mem.Allocator, io: std.Io, cart: []const u8, silent: bool, home: []const u8) !Boot {
    const first_pass = inject.symbol("AudioFrame") orelse return error.MissingSymbol;
    const state = inject.symbol("VarAudState") orelse return error.MissingSymbol;
    const up = inject.symbol("VarAudUpFrames") orelse return error.MissingSymbol;

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, trace.out_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = stem ++ ".sfc", .data = cart });
    var lua: std.Io.Writer.Allocating = .init(gpa);
    defer lua.deinit();
    try lua.writer.print(
        \\-- Generated by src/audioboot_main.zig. Do not edit.
        \\local sram = emu.memType.snesSaveRam
        \\local wram = emu.memType.snesWorkRam
        \\local FIRST, STATE, UP = 0x{X:0>6}, 0x{X:0>4}, 0x{X:0>4}
        \\local BASE, MARKER, WATCHDOG = {d}, {d}, {d}
        \\local frames, done = 0, false
        \\if {s} then
        \\  -- The APU ports read 0: no $BBAA, and no echo for the probe.
        \\  for _, bank in ipairs({{0x00, 0x80}}) do
        \\    local at = bank * 0x10000 + 0x2140
        \\    emu.addMemoryCallback(function() return 0 end, emu.callbackType.read,
        \\      at, at + 3, emu.cpuType.snes, emu.memType.snesMemory)
        \\  end
        \\end
        \\emu.addMemoryCallback(function()
        \\  if done then return end
        \\  done = true
        \\  emu.write(BASE, MARKER, sram)
        \\  emu.write(BASE + 1, emu.read(STATE, wram), sram)
        \\  emu.write(BASE + 2, emu.read(UP, wram), sram)
        \\  emu.write(BASE + 3, emu.read(UP + 1, wram), sram)
        \\  emu.write(BASE + 4, frames & 0xFF, sram)
        \\  emu.write(BASE + 5, frames >> 8, sram)
        \\  emu.stop(0)
        \\end, emu.callbackType.exec, FIRST, FIRST, emu.cpuType.snes, emu.memType.snesMemory)
        \\emu.addEventCallback(function()
        \\  frames = frames + 1
        \\  if frames > WATCHDOG then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{
        first_pass,                        @as(u16, @truncate(state)), @as(u16, @truncate(up)),
        report_at,                         marker,                     watchdog_frames,
        if (silent) "true" else "false",
    });
    try dir.writeFile(io, .{ .sub_path = stem ++ ".lua", .data = lua.written() });

    const srm = try trace.savePath(gpa, io, home, stem);
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.mesen_path, cart_name, "--testrunner", lua_name, "--timeout=60" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;
    if (code == 1) return error.CartNeverReachedAFrame;
    if (code != 0) return error.CartDidNotFinish;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, srm, gpa, .limited(trace.sram_bytes * 2));
    if (bytes.len < report_at + 6 or bytes[report_at] != marker) return error.NoReport;
    return .{
        .state = bytes[report_at + 1],
        .up_frames = std.mem.readInt(u16, bytes[report_at + 2 ..][0..2], .little),
        .frames = std.mem.readInt(u16, bytes[report_at + 4 ..][0..2], .little),
    };
}
