//! The Queen's room on the Game Boy: what `ENTER_QUEEN` leaves, and what the
//! LYC handler changes partway down each frame (1.0 Step 6).
//!
//! The room is entered the way the original's own debug warp entered it: door
//! $19D's index set between frames and the main loop left to run it
//! (`queen.enter`). The rule against forcing state binds the cart, not the
//! reference.
//!
//! What the raster split is, from the handler (03:$7C7F) and the vblank that
//! builds its list (`VBlank_drawQueen`, 03:$7CF0): the window is the Queen's
//! head, from WY to `queen_headBottomY`; between `queen_bodyY` and the body's
//! bottom SCX is `queen_bodyXScroll` and BGP `queen_bodyPalette` when that is
//! non-zero; below it SCX is the room's and BGP $93; and from line $87 the
//! window is off and the background is scrolled to (0, $70), where the room's
//! status bar sits in the map. The per-line `ppu.LineState` is that list
//! measured rather than read.

const std = @import("std");
const harness = @import("gb/harness.zig");
const ppu_mod = @import("gb/ppu.zig");
const room = @import("room.zig");
const probe = @import("gb/probe.zig");

/// The door that runs `ENTER_QUEEN`. Door $13B's `IF_MET_LESS` branch runs it.
pub const enter_door: u16 = 0x19D;

/// $D08B. $11 while the fight's room is up.
pub const room_flag_addr: u16 = 0xD08B;
pub const room_flag_fight: u8 = 0x11;

/// The Queen's display variables (`ram/wram.asm`, $C3A0-$C3D2).
pub const body_y_addr: u16 = 0xC3A0;
pub const body_x_scroll_addr: u16 = 0xC3A1;
pub const body_height_addr: u16 = 0xC3A2;
pub const head_x_addr: u16 = 0xC3A8;
pub const head_y_addr: u16 = 0xC3A9;
pub const head_bottom_y_addr: u16 = 0xC3AC;
pub const interrupt_list_addr: u16 = 0xC3AD;
pub const interrupt_list_len: usize = 9;
pub const state_addr: u16 = 0xC3C3;
pub const body_palette_addr: u16 = 0xC3D2;
/// `scrollX`/`scrollY`, what the room's lines are scrolled by.
pub const scroll_y_addr: u16 = 0xC205;
pub const scroll_x_addr: u16 = 0xC206;

/// One frame of the fight as the Game Boy drew it.
pub const Frame = struct {
    lines: [ppu_mod.height]ppu_mod.LineState,
    shades: [ppu_mod.pixels]ppu_mod.Shade,
    complete: bool,
    room_flag: u8,
    state: u8,
    body_y: u8,
    body_x_scroll: u8,
    body_height: u8,
    body_palette: u8,
    head_x: u8,
    head_y: u8,
    head_bottom_y: u8,
    scroll_x: u8,
    scroll_y: u8,
    list: [interrupt_list_len]u8,
    /// The window's map, $9C00-$9DFF: the head is its top rows.
    window_map: [0x200]u8,
    /// Samus and the camera, (screen << 8) | pixel, and her pose ($D020).
    samus_y: u16,
    samus_x: u16,
    cam_y: u16,
    cam_x: u16,
    pose: u8,
};

pub const Error = error{NeverEnteredQueen};

/// One stretch of a case's pad: `keys` held from sampled frame `from` until
/// the next hold's. Names are Mesen's (`y` is the Game Boy's B).
pub const Hold = struct {
    from: u16,
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    /// The jump: the Game Boy's A, the cart's B (`!PAD_JUMP`).
    b: bool = false,
    y: bool = false,
    select: bool = false,

    pub fn buttons(h: Hold) probe.Buttons {
        var b: probe.Buttons = .{};
        if (h.right) b.dpad &= ~@as(u4, 1);
        if (h.left) b.dpad &= ~@as(u4, 2);
        if (h.up) b.dpad &= ~@as(u4, 4);
        if (h.down) b.dpad &= ~@as(u4, 8);
        if (h.b) b.buttons &= ~@as(u4, 1);
        if (h.y) b.buttons &= ~@as(u4, 2);
        if (h.select) b.buttons &= ~@as(u4, 4);
        return b;
    }
};

/// The hold in force on sampled frame `f`.
pub fn holdAt(script: []const Hold, f: usize) Hold {
    var h: Hold = .{ .from = 0 };
    for (script) |s| {
        if (s.from <= f) h = s;
    }
    return h;
}

/// Boot into play, run door $19D, and record `count` frames from the first
/// one drawn whole with the fight's flag up.
pub fn measure(a: std.mem.Allocator, rom: []const u8, count: usize) ![]Frame {
    return measureScripted(a, rom, count, &.{});
}

/// `measure` with the pad held to `script` (1.0 Step 19c). Frame `i` here is
/// the Queen oracle's sampled frame `i - 1`, so the script is shifted by one.
pub fn measureScripted(a: std.mem.Allocator, rom: []const u8, count: usize, script: []const Hold) ![]Frame {
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{}); // the appearance, as the crawl's new game
    const ppu = try a.create(ppu_mod.Ppu);
    defer a.destroy(ppu);
    ppu.* = .{};
    m.sys.bus.video = ppu.video();
    try enter(&m);

    const out = try a.alloc(Frame, count);
    for (out, 0..) |*f, fi| {
        _ = try m.runFrames(1, if (fi == 0) .{} else holdAt(script, fi - 1).buttons());
        f.lines = ppu.lines;
        f.shades = ppu.frame;
        f.complete = ppu.complete();
        f.room_flag = m.read(room_flag_addr);
        f.state = m.read(state_addr);
        f.body_y = m.read(body_y_addr);
        f.body_x_scroll = m.read(body_x_scroll_addr);
        f.body_height = m.read(body_height_addr);
        f.body_palette = m.read(body_palette_addr);
        f.head_x = m.read(head_x_addr);
        f.head_y = m.read(head_y_addr);
        f.head_bottom_y = m.read(head_bottom_y_addr);
        f.scroll_x = m.read(scroll_x_addr);
        f.scroll_y = m.read(scroll_y_addr);
        for (&f.list, 0..) |*b, i| b.* = m.read(interrupt_list_addr + @as(u16, @intCast(i)));
        for (&f.window_map, 0..) |*b, i| b.* = m.sys.bus.vram[0x1C00 + i];
        f.samus_y = @as(u16, m.read(room.samus_screen_y_addr)) << 8 | m.read(room.samus_pixel_y_addr);
        f.samus_x = @as(u16, m.read(room.samus_screen_x_addr)) << 8 | m.read(room.samus_pixel_x_addr);
        f.cam_y = @as(u16, m.read(room.camera_screen_y_addr)) << 8 | m.read(room.camera_pixel_y_addr);
        f.cam_x = @as(u16, m.read(room.camera_screen_x_addr)) << 8 | m.read(room.camera_pixel_x_addr);
        f.pose = m.read(0xD020);
    }
    return out;
}

/// Door $19D run by the main loop itself: its index set between frames, as
/// the original's debug warp sets it (`loadDoorIndex`, 00:$0C37), and the
/// frames run until the interpreter has cleared it. **Not `room.loadRoom`**,
/// which calls the interpreter wherever the frame was paused: the first time
/// it was used here the loop resumed inside `collision_samusEnemiesDown` with
/// the temporaries it had before the door, and lifted Samus $6C off nothing.
pub fn enter(m: *harness.Machine) !void {
    m.write(room.door_index_addr, @truncate(enter_door));
    m.write(room.door_index_addr + 1, @truncate(enter_door >> 8));
    var waited: usize = 0;
    while (m.read(room.door_index_addr) != 0 or m.read(room.door_index_addr + 1) != 0) : (waited += 1) {
        if (waited > 600) return Error.NeverEnteredQueen;
        _ = try m.runFrames(1, .{});
    }
    if (m.read(room_flag_addr) != room_flag_fight) return Error.NeverEnteredQueen;
}

/// A run of lines that latched the same registers.
pub const Band = struct { first: u8, state: ppu_mod.LineState };

/// The frame's lines, folded into bands wherever a register changed.
pub fn bands(f: *const Frame, out: []Band) []Band {
    var n: usize = 0;
    for (f.lines, 0..) |l, y| {
        if (n > 0 and std.meta.eql(out[n - 1].state, l)) continue;
        if (n == out.len) break;
        out[n] = .{ .first = @intCast(y), .state = l };
        n += 1;
    }
    return out[0..n];
}

/// Where one command of the handler's list took effect: `lyc` is the line it
/// was armed for, `line` the first line the Game Boy latched its effect on.
pub const Landing = struct { kind: u8, lyc: u8, line: ?u8 };

/// Each command of `list` (the one built in the vblank before `f` was drawn),
/// and the line its effect appeared on in `f`.
pub fn landings(f: *const Frame, list: [interrupt_list_len]u8, body_x_scroll: u8, scroll_x: u8, out: []Landing) []Landing {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < list.len and list[i] != 0xFF and n < out.len) : (i += 2) {
        const lyc = list[i];
        const kind = list[i + 1] & 0x7F;
        var line: ?u8 = null;
        var y: usize = lyc;
        while (y < ppu_mod.height) : (y += 1) {
            const l = f.lines[y];
            const hit = switch (kind) {
                1 => l.scx == body_x_scroll,
                2 => l.scx == scroll_x,
                3 => l.lcdc & 0x20 == 0,
                else => l.scy == 0x70 and l.scx == 0 and l.lcdc & 0x20 == 0,
            };
            if (hit) {
                line = @intCast(y);
                break;
            }
        }
        out[n] = .{ .kind = kind, .lyc = lyc, .line = line };
        n += 1;
        if (kind == 4) break;
    }
    return out[0..n];
}
