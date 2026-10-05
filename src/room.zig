//! The room test harness: put Samus in an arbitrary room, at an arbitrary
//! position, and let the game run from there.
//!
//! `01-requirements` (F10) asks for this so exploratory testing and regression
//! runs can start anywhere instead of at the ship. Step 15 needs it for a
//! sharper reason: a frame-for-frame comparator has to put *both* machines on
//! the same pixel of the same screen at frame 0, and neither machine can be
//! told where to start. `snes_screen.chooseBoot` picks a deterministic fixture
//! cell and `engine/main.asm` drops Samus at the camera's centre, because Phase
//! 0a has no door transition to be handed a position by. This file is the Game
//! Boy half of fixing that; the boot record's version 3 fields are the SNES
//! half, and the two are checked against each other at the bottom.
//!
//! ## Not a save record, and why that is better
//!
//! The requirement suggested synthesizing a save record, on the grounds that
//! the game's own initial-save data already carries every field. That would
//! work, and it would put the whole file-select path -- menus, checksums, the
//! new-game branch -- between the request and the result. The `WARP` handler is
//! a much shorter lever, and `probe` already established that a booted machine
//! will execute any subroutine on demand.
//!
//! `zig build disasm -- 0 0x28FB 0x2960 0x28FB` says what the handler wants,
//! and it wants very little:
//!
//!     $28FB  LD A,(HL+)      ; operand byte 0
//!     $28FC  AND $0F         ; low nibble is the map bank
//!     $28FE  LD ($D058),A
//!     $2901  LD ($D811),A
//!     $2904  LD A,(HL)       ; operand byte 1
//!     $2905  SWAP A
//!     $2907  AND $0F         ; high nibble is the screen row
//!     $2909  LDH ($C9),A
//!     $290B  LDH ($C1),A
//!     $290D  LD A,(HL+)
//!     $290E  AND $0F         ; low nibble is the screen column
//!     $2910  LDH ($CB),A
//!     $2912  LDH ($C3),A
//!
//! Two bytes at `HL`, and a direction in $D00E that picks which of four camera
//! arrangements the transition uses. That is the whole interface, and none of
//! it is a door: the door table is just where the game happens to keep its
//! operands. Handing the handler our own two bytes reaches rooms no door names.
//!
//! ## Where the operand lives
//!
//! In WRAM, at `operand_addr`. The handler consumes both bytes within its first
//! six instructions -- before the `CALL $2C5E` at $2915 -- so nothing the
//! transition subsequently does can disturb them, and the address only has to
//! be writable rather than reserved.
//!
//! ## What this does not do yet
//!
//! Position, yes; loadout, only as a mechanism. `Spawn.writes` will set any
//! address to any value, but the addresses of equipment, beam, energy, missiles
//! and the Metroid count are not pinned, and are not guessed at here. The
//! mechanical way to pin them is `watchSave` below, and the reason it has not
//! worked yet is a fact rather than an excuse -- see the test that asserts it.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const bus_mod = @import("gb/bus.zig");
const snes_screen = @import("snes_screen.zig");
const save = @import("save.zig");
const entity = @import("entity.zig");
const screens = @import("screens.zig");
const offsets = @import("offsets.zig");
const death = @import("death.zig");

const testrom = @import("testrom");

/// `zig build disasm -- 0 0x28FB 0x2960 0x28FB`. The `WARP` handler, which
/// `probe` pinned by watching the door-script interpreter dispatch to it.
pub const warp_handler: u16 = 0x28FB;

/// Where the harness puts the two operand bytes. See the module comment: the
/// handler reads them immediately, so any writable address does.
pub const operand_addr: u16 = 0xC000;

/// The transition direction, in $D00E. The handler compares it against 1, 2, 4
/// and 8 and takes a different camera arrangement for each; anything else
/// falls straight through to the `RET` at $2938, setting the room but leaving
/// the camera alone.
pub const direction_addr: u16 = 0xD00E;

/// **Renamed 2026-09-07, and the old names were wrong.** They read `settle = 1,
/// up = 2, down = 4, across = 8`. Nothing had produced a wrong result -- the
/// only caller writes 1 and never names it -- but the port's own triggers now
/// select a direction on purpose, and a scenario asking for `across` and
/// getting a downward warp would read as a port defect.
///
/// The ROM says which is which twice over, and the two readings agree. Each of
/// `handleWarp`'s four arms draws in the direction of its own name: $2939
/// (value 1) three columns at camera + $50/$60/$70, to the right; $29C4 (2) at
/// camera - $60/$70/$80, to the left; $2B04 (4) three rows above; $2A4F (8)
/// three rows below. And each of `handleCamera`'s four triggers sets the value
/// belonging to the edge it fired on: 00:$092B sets 1 where scrolling right is
/// blocked, $09A5 sets 2 on the left, $0AD6 sets 4 on the up and $0A66 sets 8
/// on the down.
pub const Direction = enum(u8) {
    /// The arrangement `probe.runDoors` uses across all 512 doors, because it
    /// is the one whose camera arithmetic is disassembled at $2939 -- not
    /// because a door sweep is a rightward transition.
    right = 1,
    left = 2,
    up = 4,
    down = 8,
    /// Set the room and leave the camera where it was.
    none = 0,
};

/// The bank the handler is *told* to warp to. Transient: it is the handler's
/// own argument slot, and the game clears it once the transition is done.
pub const warp_bank_addr: u16 = 0xD058;

/// The map bank the game holds on to. $2901: `LD ($D811),A`, the second place
/// the handler puts its operand's low nibble.
///
/// Both this and `warp_bank_addr` survive a spawn and stay put for as long as
/// the game runs in that room, so either would do; this one is used because it
/// is the copy the handler makes rather than the slot it was handed.
///
/// The third candidate, $D04E, is **not** a map bank and is worth naming so
/// nobody reaches for it again: $293C copies the operand there and writes the
/// same value to $2100, the MBC's bank register, so it is a shadow of *whatever
/// bank is currently mapped*. A hundred frames later it reads 4, because the
/// main loop has been in and out of the sound driver.
pub const map_bank_addr: u16 = 0xD811;

/// The game's own record of which bank is mapped at $4000, written beside every
/// `LD ($2100),A`. Not a map bank -- see `map_bank_addr` -- but `drawRoom`
/// keeps it truthful, because the engine reads it back when it remaps.
pub const bank_shadow_addr: u16 = 0xD04E;
/// The quad the `WARP` handler writes, which is **not** Samus.
///
/// The handler seeds it from the destination and the game maintains it
/// afterwards for its own purposes: over 3600 frames of a published run
/// $FFC8/$FFC9 takes 41 writes, all from initialisation and transition code at
/// 0:$0470-$04B7, 0:$0A92 and 0:$0B24, while $FFCA/$FFCB takes 553 from the
/// scroll-edge routines at 0:$0953-$0A02 -- the same family as the column draws
/// at 0:$0700. 00:$32CF and 00:$34AE subtract it from Samus's sampled position
/// to reach entity space, which is what a scroll origin is for.
///
/// It is still what a spawn has to seed, because the handler reads it; it is
/// not what a comparator should read. See `samus_pixel_y_addr`.
pub const screen_row_addr: u16 = 0xFFC9;
pub const screen_col_addr: u16 = 0xFFCB;
pub const pixel_y_addr: u16 = 0xFFC8;
pub const pixel_x_addr: u16 = 0xFFCA;

/// **Samus's position.** $FFC0/$FFC1 is her Y as (pixel, screen); $FFC2/$FFC3
/// is her X.
///
/// *This documentation replaces a wrong reading that cost Step 15 three
/// sessions, and the wrong reading is kept here because the mistake is
/// instructive.* It said the original keeps Samus's position **twice** -- that
/// the `WARP` handler storing each screen number to two places, `LDH ($C9),A`
/// then `LDH ($C1),A` for the row and `LDH ($CB),A` then `LDH ($C3),A` for the
/// column, made $FFC0-$FFC3 and $FFC8-$FFCB copies of one another. They are
/// not copies. They agree at the instant of a transition, which is the only
/// instant that handler runs, and diverge on the next frame of play.
///
/// **Only this quad is Samus**, and it is not an argument any more: `locate.zig`
/// replays a published tool-assisted run and records which instruction writes
/// what. Over 3600 frames, $FFC2/$FFC3 takes 4740 writes and every one comes
/// from the movement routines at 0:$1C2F-$1D46 -- `samus_walkRight` reads it,
/// adds the walk speed, stores it back and carries into the screen nibble with
/// `AND $0F`. $FFC0/$FFC1 takes 409 from `samus_moveVertical` at 0:$1D5A and
/// 0:$1D9C. Every collision routine samples from this quad and no other.
///
/// See `warp_pixel_y_addr` for what the other one turned out to be.
pub const samus_pixel_y_addr: u16 = 0xFFC0;
pub const samus_screen_y_addr: u16 = 0xFFC1;
pub const samus_pixel_x_addr: u16 = 0xFFC2;
pub const samus_screen_x_addr: u16 = 0xFFC3;

/// Kept under the old names because `probe.zig` and `spawn` still write them.
pub const collide_pixel_y_addr: u16 = samus_pixel_y_addr;
pub const collide_pixel_x_addr: u16 = samus_pixel_x_addr;

/// The first and last banks that hold map data, from `coverage.bank_roles`.
pub const map_bank_first: u8 = 0x9;
pub const map_bank_last: u8 = 0xF;

// ---- Loading the room, not just moving Samus -------------------------------

/// The door-script interpreter, and the door index it reads.
///
/// A `WARP` moves Samus and the camera; it does **not** load a room. What loads
/// a room is the door script the warp is the last opcode of: `door.zig`'s
/// `copy` and `load` ops fill VRAM, `tiletable` selects the metatile table the
/// screen bodies are expanded through, and `collision` and `solidity` select
/// the tables the physics reads. Called on its own, `warp_handler` inherits
/// whichever of those the previous room left behind -- which is how the
/// reference came to be standing in a Ruins exterior screen expanded through
/// the *surface* metatile table, matching no table at all.
///
/// The entry point is `probe.interp_entry`, found by searching the ROM for the
/// instruction that loads the door-pointer table's address. Duplicated rather
/// than imported for the same reason `probe` duplicates `door.zig`'s
/// constants, and checked against it by a test at the bottom of this file.
pub const door_interp: u16 = 0x239C;
pub const door_index_addr: u16 = 0xD08E;

/// Draw one column of the room: sixteen metatiles down, two tiles wide.
///
/// `zig build disasm -- 0 0x07E4 0x0860 0x07E4`. It reads the camera out of
/// $FFCC-$FFCF, turns it into a screen pointer and a background-map destination
/// through $0835, and queues sixteen 2x2 metatile writes into `vram_queue`.
///
/// **One column** -- and that is the second half of why a warp alone does not
/// load a room. The handler calls this three times and leaves the other
/// twenty-nine to the scroll-edge routines at $0700, which draw a column each
/// time the camera crosses a metatile boundary. A spawn crosses nothing, so six
/// of the map's thirty-two columns were the destination room and the rest were
/// still the room before it.
///
/// That is a property of the `WARP` handler, not of every transition: 95 of the
/// 497 decodable door scripts carry a `fadeout`, 87 of them beside a warp, so a
/// good fifth of the game's doors do cut to black rather than scroll. What they
/// have in common is that the *handler* draws three columns either way -- a
/// fade hides the rest arriving, it does not draw it.
pub const draw_column: u16 = 0x07E4;

/// Update the sound driver, then halt until vblank.
///
/// The idiom the warp handler puts between its own three draws, and for the
/// reason `drawRoom` needs it too: the queue is drained by the vblank handler,
/// and a second column queued without a frame in between would overrun it.
pub const wait_frame: u16 = 0x2C5E;

/// The background-map write queue, and the moving pointer into it. $2942
/// reseeds the pointer before each draw; so does `drawRoom`.
pub const vram_queue: u16 = 0xDE00;
pub const vram_queue_ptr_lo_addr: u16 = 0xFFAF;
pub const vram_queue_ptr_hi_addr: u16 = 0xFFB0;

/// The **drawing origin**: the camera rounded down to a whole screen. $0835
/// reads all four -- the screen halves pick the screen body, the pixel halves
/// pick both the metatile within it and where in the background map the tiles
/// land -- which is why `drawRoom` walks these and not the camera.
///
/// Not the camera, though it was called that until 2026-08-31. 00:$0675 zeroes
/// $FFCC and $FFCE and copies $FFC9/$FFCB into $FFCD/$FFCF, so this quad steps
/// a screen at a time while the camera moves a pixel at a time. See
/// `camera_pixel_y_addr`.
pub const draw_origin_pixel_y_addr: u16 = 0xFFCC;
pub const draw_origin_screen_y_addr: u16 = 0xFFCD;
pub const draw_origin_pixel_x_addr: u16 = 0xFFCE;
pub const draw_origin_screen_x_addr: u16 = 0xFFCF;

/// The camera, in the same (pixel, screen) pair per axis Samus's position uses.
/// Maintained by 00:$08FE; see `tas.camera_pixel_y_addr` for how it was told
/// apart from the drawing origin.
pub const camera_pixel_y_addr: u16 = 0xFFC8;
pub const camera_screen_y_addr: u16 = 0xFFC9;
pub const camera_pixel_x_addr: u16 = 0xFFCA;
pub const camera_screen_x_addr: u16 = 0xFFCB;

/// A screen is 16x16 metatiles of 16x16 pixels, which is 32x32 tiles -- exactly
/// the background map. So one screen drawn from its own origin fills the map
/// and nothing wraps in from the screen beside it.
pub const columns_per_screen: usize = 16;
pub const metatile_pixels: u8 = 16;

pub const Error = harness.Error || error{ BadMapBank, WarpDidNotReturn, NeverStartedPlaying, RoomDidNotLoad, RoomDidNotDraw };

pub const Spawn = struct {
    /// $9-$F. The handler masks to a nibble, so a bank outside the map range
    /// would silently select something that is not map data; refused instead.
    map_bank: u8,
    /// 0-15 each. The screen grid is 16x16 per bank, indexed `row * 16 + col`,
    /// which is what `probe.runDoors` proved by watching which screen-pointer
    /// entry the engine read.
    screen_row: u4,
    screen_col: u4,
    /// Position within the screen. Kept across a transition by the original, so
    /// these are written after the warp rather than through it.
    pixel_y: u8 = 0x80,
    pixel_x: u8 = 0x80,
    direction: Direction = .right,
    /// The loadout, by name. Null leaves the game's own value alone.
    ///
    /// Step 14 shipped this as an unnamed address/value list because the
    /// addresses were not pinned. Step 15 pinned them, though not by the route
    /// the plan expected: no tool-assisted run reaches a save station before
    /// our replay of it diverges, so the addresses come from the routine that
    /// *writes* a record rather than from watching one be written. See
    /// `save.zig` for how it was found and for which fields are still unnamed.
    loadout: Loadout = .{},
    /// Anything `Loadout` does not name, still by address. `save.fields` is
    /// the list of addresses worth setting.
    writes: []const harness.Write = &.{},
    /// The door script to run before the warp, so the room is *loaded* and not
    /// merely arrived at. See `door_interp`.
    ///
    /// Null leaves whatever the machine had, which is what Step 14's tests
    /// want -- they ask where Samus ended up, and that answer does not depend
    /// on which tiles were drawn around her. Anything that reads the picture,
    /// or the collision data behind it, has to name a door.
    /// `screens.assign` pairs one with every in-use cell, and
    /// `snes_screen.Boot.door_index` is that pairing for the cart's boot cell.
    door_index: ?u16 = null,
    /// Instruction budget for the warp handler itself.
    budget: usize = 4_000_000,
};

/// The parts of the save record this harness can set by name.
///
/// Every field here is a `save.Field` with a name, minus the position ones,
/// which `Spawn` already sets. Values are as the game stores them: BCD for the
/// counts, so 30 missiles is `0x30`.
pub const Loadout = struct {
    energy: ?u8 = null,
    missiles: ?u8 = null,
    missile_capacity: ?u8 = null,
    metroid_count_real: ?u8 = null,
    metroid_count_displayed: ?u8 = null,

    /// The address each field is stored at, taken from `save.fields` by name
    /// rather than repeated here, so a correction there reaches this.
    fn addrOf(comptime name: []const u8) u16 {
        for (save.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.src;
        }
        @compileError("no save-record field named " ++ name);
    }

    pub fn apply(self: Loadout, m: *harness.Machine) void {
        inline for (@typeInfo(Loadout).@"struct".fields) |f| {
            if (@field(self, f.name)) |v| m.write(comptime addrOf(f.name), v);
        }
    }
};

/// Where Samus actually ended up, read back out of the machine.
///
/// Read back rather than echoed: the point of the harness is that the request
/// and the result can be compared, and a struct that repeated the request would
/// make every check pass.
pub const Placement = struct {
    /// The bank the cartridge is mapped to: $D04E, not the handler's argument.
    map_bank: u8,
    /// What the handler was told, for comparison. Cleared by the game once the
    /// transition completes, so it is diagnostic rather than load-bearing.
    warp_bank: u8,
    screen_row: u8,
    screen_col: u8,
    pixel_y: u8,
    pixel_x: u8,

    /// The full position on each axis.
    ///
    /// The screen number is the high byte and the pixel offset the low one --
    /// not a guess: the handler's own camera arithmetic at $294F does
    /// `LDH A,($CA) / ADD A,$50 / LDH A,($CB) / ADC A,$00`, which is a 16-bit
    /// add of $50 to exactly this pair. A screen is therefore 256 pixels on a
    /// side as far as the position is concerned.
    pub fn worldX(self: Placement) u16 {
        return (@as(u16, self.screen_col) << 8) | self.pixel_x;
    }

    pub fn worldY(self: Placement) u16 {
        return (@as(u16, self.screen_row) << 8) | self.pixel_y;
    }

    pub fn eql(a: Placement, b: Placement) bool {
        return a.map_bank == b.map_bank and
            a.worldX() == b.worldX() and
            a.worldY() == b.worldY();
    }
};

/// Put Samus in the named room at the named position.
///
/// The machine must already be booted into the game -- `harness.boot` with real
/// seconds -- because the warp handler transitions *from* somewhere. Called on
/// a machine sitting at the title screen it sets the variables and leaves the
/// game with no room to draw.
pub fn spawn(m: *harness.Machine, s: Spawn) Error!Placement {
    if (s.map_bank < map_bank_first or s.map_bank > map_bank_last) return Error.BadMapBank;

    // The room first, then the position. A door script ends with its own
    // `WARP`, so running it afterwards would undo the placement; running it
    // first means our warp overwrites the script's destination with ours and
    // keeps everything the script loaded on the way there.
    if (s.door_index) |di| try loadRoom(m, di, s.budget);

    m.write(operand_addr, s.map_bank & 0x0F);
    m.write(operand_addr + 1, (@as(u8, s.screen_row) << 4) | @as(u8, s.screen_col));
    m.write(direction_addr, @intFromEnum(s.direction));

    const out = try m.call(.{
        .addr = warp_handler,
        // HL is the operand pointer, which is the handler's whole argument.
        .regs = .{ .h = @truncate(operand_addr >> 8), .l = @truncate(operand_addr) },
        .budget = s.budget,
        // The transition copies tiles into VRAM through loops that wait on
        // vblank, exactly as a door script does -- and for exactly the reason
        // the ledger's door sweep needed, it will not finish with IME clear.
        .interrupts = true,
    });
    if (!out.returned) return Error.WarpDidNotReturn;

    // After the warp, because the original keeps them across a transition and
    // the handler therefore never writes them. Both copies: see
    // `collide_pixel_y_addr` for what happens when only one is written.
    m.write(pixel_y_addr, s.pixel_y);
    m.write(pixel_x_addr, s.pixel_x);
    m.write(collide_pixel_y_addr, s.pixel_y);
    m.write(collide_pixel_x_addr, s.pixel_x);

    // And the room has to be drawn, because the handler drew three columns of
    // it. Only worth doing when a door script has been run: without one the
    // metatile table is the previous room's, and redrawing thirty-two columns
    // through the wrong table replaces a partly wrong picture with an entirely
    // wrong one.
    if (s.door_index != null) try drawRoom(m, s.map_bank, s.screen_row, s.screen_col, s.budget);

    // **And the transition has to be declared over.** $D00E is not only the
    // handler's argument, it is the game's "a transition is in progress" flag:
    // `samus_handlePose` at 00:$0D21 opens with `LD A,($D00E) / AND A / RET NZ`,
    // so while it is set the pose machine does nothing at all. Left set, the
    // spawn looked perfect and then the next sixty frames put the map bank back
    // to zero, because the game was still waiting to finish arriving somewhere.
    // The original clears it when the transition completes; called out of
    // context, nothing is going to clear it for us.
    m.write(direction_addr, 0);

    s.loadout.apply(m);
    for (s.writes) |w| m.write(w.addr, w.value);

    return placement(m);
}

/// Run the door script that loads a room's graphics, tables and song.
///
/// The script's own `WARP` runs too, and is meant to: it leaves the game in the
/// state that follows a real transition rather than midway through one. The
/// caller's warp then moves Samus off the script's destination and onto the
/// requested cell.
pub fn loadRoom(m: *harness.Machine, index: u16, budget: usize) Error!void {
    m.write(door_index_addr, @truncate(index));
    m.write(door_index_addr + 1, @truncate(index >> 8));
    const out = try m.call(.{
        .addr = door_interp,
        .budget = budget,
        // A script copies several kilobytes into VRAM through loops that wait
        // on vblank, exactly as the warp handler does.
        .interrupts = true,
    });
    if (!out.returned) return Error.RoomDidNotLoad;
}

/// Draw one whole screen into the background map, from its own origin.
///
/// The camera is moved across the screen a metatile at a time and `draw_column`
/// called at each stop, which is what the game does over the course of a scroll
/// and what the warp handler does three times. Driving it from the screen's
/// origin rather than from the camera's actual position is deliberate: the map
/// is exactly one screen across, so a camera part-way into a screen would fill
/// the map with two halves of two different screens, and the cart -- which
/// holds one converted cell and nothing beside it -- has no second half to
/// match. The camera is put back afterwards, so the only thing this changes is
/// the picture.
pub fn drawRoom(m: *harness.Machine, map_bank: u8, screen_row: u4, screen_col: u4, budget: usize) Error!void {
    const keep_pixel_y = m.read(draw_origin_pixel_y_addr);
    const keep_screen_y = m.read(draw_origin_screen_y_addr);
    const keep_pixel_x = m.read(draw_origin_pixel_x_addr);
    const keep_screen_x = m.read(draw_origin_screen_x_addr);

    // Row 0 of the screen, so the column loop's sixteen metatile rows land
    // inside it and the wrap onto the screen below happens after the last one.
    m.write(draw_origin_pixel_y_addr, 0);
    m.write(draw_origin_screen_y_addr, screen_row);

    for (0..columns_per_screen) |i| {
        m.write(draw_origin_pixel_x_addr, @intCast(i * metatile_pixels));
        m.write(draw_origin_screen_x_addr, screen_col);
        m.write(vram_queue_ptr_lo_addr, @truncate(vram_queue));
        m.write(vram_queue_ptr_hi_addr, @truncate(vram_queue >> 8));

        // The map bank, every time round. `draw_column` reads the screen
        // pointer table at $4000 of whatever is mapped, and `wait_frame` maps
        // bank 4 for the sound driver and does not put it back -- which is why
        // the handler remaps at $2939, $2971 and $299B, once before each of its
        // three draws. Drawn without this, one column of sixteen came from the
        // map and the other fifteen from the sound driver's bank.
        m.write(bank_shadow_addr, map_bank);
        // Deliberately *without* interrupts. The routine only fills the queue
        // -- it never waits on vblank -- and the vblank handler is what drains
        // it. Left enabled, a frame landing mid-column drains a queue whose
        // terminator has not been written yet. `Call.interrupts` clears IME
        // rather than saving it, and the frame wait below needs it back, so it
        // is put back by hand.
        const ime = m.sys.cpu.ime;
        const drew = try m.call(.{
            .addr = draw_column,
            .bank = map_bank,
            .budget = budget,
            .interrupts = false,
        });
        m.sys.cpu.ime = ime;
        if (!drew.returned) return Error.RoomDidNotDraw;
        const drained = try m.call(.{ .addr = wait_frame, .budget = budget, .interrupts = true });
        if (!drained.returned) return Error.RoomDidNotDraw;
    }

    m.write(draw_origin_pixel_y_addr, keep_pixel_y);
    m.write(draw_origin_screen_y_addr, keep_screen_y);
    m.write(draw_origin_pixel_x_addr, keep_pixel_x);
    m.write(draw_origin_screen_x_addr, keep_screen_x);
}

/// Where Samus actually is, read from the quad the movement routines maintain.
///
/// **Corrected 2026-08-31.** This read $FFC8/$FFCA, which the `WARP` handler
/// seeds and the scroll code then maintains for itself. Immediately after a
/// spawn the two quads agree, so every round-trip test passed; a frame of play
/// later they do not, and the oracle spent 320 frames comparing a constant
/// against a constant while reporting the port at fault. See
/// `samus_pixel_y_addr`.
pub fn placement(m: *harness.Machine) Placement {
    return .{
        .map_bank = m.read(map_bank_addr),
        .warp_bank = m.read(warp_bank_addr),
        .screen_row = m.read(samus_screen_y_addr),
        .screen_col = m.read(samus_screen_x_addr),
        .pixel_y = m.read(samus_pixel_y_addr),
        .pixel_x = m.read(samus_pixel_x_addr),
    };
}

// ---- Is the game actually playing? ----------------------------------------

/// The counter `samus_handlePose` increments on every frame it runs.
///
/// `zig build disasm -- 0 0x0D21 0x0D60 0x0D21`, third instruction in:
/// `LD A,($D072) / INC A / LD ($D072),A`, before any of the routine's early
/// outs. So it advances on exactly the frames the pose machine runs on, which
/// is the definition of the game playing rather than merely running.
pub const pose_frame_counter_addr: u16 = 0xD072;

/// Whether the pose machine is running, measured rather than assumed.
///
/// **This exists because it was not true when it needed to be.** `harness.boot`
/// taps Start every thirty frames for thirty seconds, which is how every test
/// in this repository gets into the game -- and Start is also Metroid II's
/// pause button. The first tap starts the game and the twenty-nine after it
/// toggle the pause, an odd number of times, so the schedule reliably ends with
/// the game *paused*. Nothing noticed: a paused game still draws, still holds
/// the position the warp handler wrote, and still passes every check Step 14's
/// room harness makes, because those check variables rather than motion. What
/// does not survive it is a frame-for-frame comparison, where the original
/// stands perfectly still for three hundred and twenty frames.
pub fn playing(m: *harness.Machine) !bool {
    const before = m.read(pose_frame_counter_addr);
    _ = try m.runFrames(4, .{});
    return m.read(pose_frame_counter_addr) != before;
}

/// Boot, and keep tapping Start until the game is actually playing.
///
/// One tap either starts the game or toggles the pause, and there is no way to
/// tell which from outside -- so it taps and checks, rather than counting.
pub fn bootIntoPlay(allocator: std.mem.Allocator, rom: []const u8) !harness.Machine {
    var m = try harness.boot(allocator, rom, harness.boot_seconds_default);
    errdefer m.deinit();

    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        if (try playing(&m)) return m;
        // Press and release: the game reads the button's edge, so a hold does
        // nothing a tap does not.
        var b: probe.Buttons = .{};
        b.buttons &= ~@as(u4, 0b1000);
        _ = try m.runFrames(8, b);
        _ = try m.runFrames(20, .{});
    }
    return error.NeverStartedPlaying;
}

// ---- Finding the loadout, by watching the game write it -------------------

/// One write into cartridge RAM, with the instruction that made it.
pub const SaveWrite = struct {
    pc: u16,
    /// The bank mapped at $4000-$7FFF when it wrote.
    ///
    /// Not decoration: the one site any run has ever reached is at $4290,
    /// which is inside the banked window, so a PC on its own does not say
    /// which code wrote and cannot be disassembled.
    bank: u8,
    addr: u16,
    value: u8,
};

pub const SaveReport = struct {
    writes: []SaveWrite,
    /// Distinct cartridge-RAM addresses written.
    distinct: usize,
    /// Distinct program counters that wrote any of them.
    sites: usize,
    low: u16,
    high: u16,
    /// An allocation failed while recording, so `writes` or `sites` is short.
    /// Not the same as `writes` stopping at the log's limit, which is asked for.
    incomplete: bool = false,

    pub fn deinit(self: *SaveReport, allocator: std.mem.Allocator) void {
        allocator.free(self.writes);
        self.writes = &.{};
    }
};

const sram_low: u16 = 0xA000;
const sram_high: u16 = 0xBFFF;

/// Collects cartridge-RAM writes, with the program counter that made each one.
///
/// Split out of `watchSave` so `tas.zig` can point the same watcher at a
/// published TAS run. That is not a refactor for tidiness: `watchSave`'s own
/// schedule is ninety seconds of random input, and the test below records what
/// that reaches — one byte, the file counter — because the game only writes a
/// record at a save station. A run that finishes the game reaches several, and
/// it is the same watcher that has to see them or the two answers would not be
/// comparable.
pub const SaveLog = struct {
    /// The caller sets this to the PC before each step. A write hook sees only
    /// the bus, so the instruction that wrote has to be handed in.
    pc: u16 = 0,
    list: std.ArrayList(SaveWrite) = .empty,
    allocator: std.mem.Allocator,
    seen: [0x2000]bool = @splat(false),
    distinct: usize = 0,
    sites: std.AutoHashMap(u16, void),
    low: u16 = 0xFFFF,
    high: u16 = 0,
    limit: usize,
    /// An allocation failed in `note`. The write hook cannot return an error,
    /// so this is how the report says it is missing something.
    incomplete: bool = false,

    pub fn init(allocator: std.mem.Allocator, limit: usize) SaveLog {
        return .{
            .allocator = allocator,
            .sites = std.AutoHashMap(u16, void).init(allocator),
            .limit = limit,
        };
    }

    pub fn deinit(self: *SaveLog) void {
        self.list.deinit(self.allocator);
        self.sites.deinit();
    }

    pub fn attach(self: *SaveLog, m: *harness.Machine) void {
        m.sys.bus.write_watch = .{ .ctx = self, .write = onWrite };
    }

    /// Hands over the collected writes; the log keeps the counters. The
    /// returned `SaveReport` owns its slice and is freed with the same
    /// allocator this log was built with.
    pub fn report(self: *SaveLog) !SaveReport {
        return .{
            .writes = try self.list.toOwnedSlice(self.allocator),
            .distinct = self.distinct,
            .sites = self.sites.count(),
            .low = self.low,
            .high = self.high,
            .incomplete = self.incomplete,
        };
    }

    fn onWrite(ctx: *anyopaque, bus: *const bus_mod.Bus, addr: u16, value: u8) void {
        const self: *SaveLog = @ptrCast(@alignCast(ctx));
        if (addr < sram_low or addr > sram_high) return;
        const bank: u8 = if (self.pc < 0x4000)
            @truncate(bus.cart.lowBank())
        else
            @truncate(bus.cart.highBank());
        self.note(bank, addr, value);
    }

    /// The record-keeping half of `onWrite`, apart from the bus so it can be
    /// tested without a machine. `addr` is in cartridge RAM.
    fn note(self: *SaveLog, bank: u8, addr: u16, value: u8) void {
        const i = addr - sram_low;
        if (!self.seen[i]) {
            self.seen[i] = true;
            self.distinct += 1;
        }
        if (addr < self.low) self.low = addr;
        if (addr > self.high) self.high = addr;
        self.sites.put(self.pc, {}) catch {
            self.incomplete = true;
        };
        if (self.list.items.len < self.limit) {
            self.list.append(self.allocator, .{
                .pc = self.pc,
                .bank = bank,
                .addr = addr,
                .value = value,
            }) catch {
                self.incomplete = true;
            };
        }
    }
};

/// One read of cartridge RAM, with the instruction that made it.
pub const LoadRead = struct {
    pc: u16,
    bank: u8,
    addr: u16,
    value: u8,
};

pub const LoadReport = struct {
    reads: []LoadRead,
    distinct: usize,
    sites: usize,
    low: u16,
    high: u16,
    /// As `SaveReport.incomplete`.
    incomplete: bool = false,

    pub fn deinit(self: *LoadReport, allocator: std.mem.Allocator) void {
        allocator.free(self.reads);
        self.reads = &.{};
    }
};

/// The mirror of `SaveLog`, and the one that actually gets to run.
///
/// Step 14 deferred the loadout addresses to "watch the game write a record",
/// and Step 15 then measured that neither published tool-assisted run reaches
/// a save station before our replay of it diverges: 40 240 frames of the any%
/// run and 20 590 of the 100% one, and one byte of cartridge RAM written in
/// each -- the file counter at $A0C0, nothing else. Waiting for a write is
/// waiting for something that does not happen.
///
/// Reading is the other direction of the same copy and it happens on every
/// boot: the game loads a record into WRAM before it can play from it. So the
/// mapping from record offset to WRAM address is recovered from the *load*,
/// which is the same table read the other way round.
pub const LoadLog = struct {
    pc: u16 = 0,
    list: std.ArrayList(LoadRead) = .empty,
    allocator: std.mem.Allocator,
    seen: [0x2000]bool = @splat(false),
    distinct: usize = 0,
    sites: std.AutoHashMap(u16, void),
    low: u16 = 0xFFFF,
    high: u16 = 0,
    limit: usize,
    /// As `SaveLog.incomplete`.
    incomplete: bool = false,

    pub fn init(allocator: std.mem.Allocator, limit: usize) LoadLog {
        return .{
            .allocator = allocator,
            .sites = std.AutoHashMap(u16, void).init(allocator),
            .limit = limit,
        };
    }

    pub fn deinit(self: *LoadLog) void {
        self.list.deinit(self.allocator);
        self.sites.deinit();
    }

    pub fn attach(self: *LoadLog, m: *harness.Machine) void {
        m.sys.bus.read_watch = .{ .ctx = self, .read = onRead };
    }

    pub fn report(self: *LoadLog) !LoadReport {
        return .{
            .reads = try self.list.toOwnedSlice(self.allocator),
            .distinct = self.distinct,
            .sites = self.sites.count(),
            .low = self.low,
            .high = self.high,
            .incomplete = self.incomplete,
        };
    }

    fn onRead(ctx: *anyopaque, bus: *const bus_mod.Bus, addr: u16, value: u8) void {
        const self: *LoadLog = @ptrCast(@alignCast(ctx));
        if (addr < sram_low or addr > sram_high) return;
        const bank: u8 = if (self.pc < 0x4000)
            @truncate(bus.cart.lowBank())
        else
            @truncate(bus.cart.highBank());
        self.note(bank, addr, value);
    }

    /// The record-keeping half of `onRead`, apart from the bus so it can be
    /// tested without a machine. `addr` is in cartridge RAM.
    fn note(self: *LoadLog, bank: u8, addr: u16, value: u8) void {
        const i = addr - sram_low;
        if (!self.seen[i]) {
            self.seen[i] = true;
            self.distinct += 1;
        }
        if (addr < self.low) self.low = addr;
        if (addr > self.high) self.high = addr;
        self.sites.put(self.pc, {}) catch {
            self.incomplete = true;
        };
        if (self.list.items.len < self.limit) {
            self.list.append(self.allocator, .{
                .pc = self.pc,
                .bank = bank,
                .addr = addr,
                .value = value,
            }) catch {
                self.incomplete = true;
            };
        }
    }
};

/// Boot the game normally and record every cartridge-RAM read on the way in.
///
/// `boot_seconds` is the same schedule `harness.boot` uses -- Start tapped
/// until the game starts -- because the record is loaded as part of starting,
/// and nothing more directed is needed to make that happen.
pub fn watchLoad(
    allocator: std.mem.Allocator,
    rom: []const u8,
    boot_seconds: usize,
    limit: usize,
) !LoadReport {
    var m = try harness.boot(allocator, rom, 0);
    defer m.deinit();

    var log = LoadLog.init(allocator, limit);
    defer log.deinit();
    log.attach(&m);

    const frames = boot_seconds * 60;
    const cap = frames * harness.Machine.instructions_per_frame_cap + 1_000_000;
    var guard: u64 = 0;
    while (m.sys.frames < frames and guard < cap) : (guard += 1) {
        log.pc = m.sys.cpu.pc;
        _ = try m.sys.step();
        const b = probe.bootButtons(@intCast(m.sys.frames));
        m.sys.bus.setKeys(b.dpad, b.buttons);
    }
    m.sys.bus.read_watch = null;

    return log.report();
}

/// Watch the game write its own save record, and report where and from what.
///
/// This is the mechanical route to the loadout addresses the requirement asks
/// the room harness to be able to set -- equipment, beam, energy, missiles and
/// the Metroid count. Reading them off a disassembly's labels is exactly what
/// `01-requirements` says not to do; watching the game copy them into cartridge
/// RAM names both the copying routine and every field's offset in the record,
/// and the source address of each field then falls out of disassembling that
/// one routine.
///
/// It reports what it saw rather than deciding anything: a run that reaches no
/// save station writes no record, and an empty report is the honest answer to
/// "does the opening of the game save".
pub fn watchSave(
    allocator: std.mem.Allocator,
    rom: []const u8,
    boot_seconds: usize,
    explore_seconds: usize,
    limit: usize,
) !SaveReport {
    var m = try harness.boot(allocator, rom, 0);
    defer m.deinit();

    var log = SaveLog.init(allocator, limit);
    defer log.deinit();
    log.attach(&m);

    // The watcher needs the PC of the instruction that wrote, and a write hook
    // sees only the bus. Stepping here rather than through `runScript` is what
    // lets the PC be recorded alongside it.
    var frame_base: u64 = 0;
    for ([_]struct { frames: u64, explore: bool }{
        .{ .frames = boot_seconds * 60, .explore = false },
        .{ .frames = explore_seconds * 60, .explore = true },
    }) |phase| {
        const start = m.sys.frames;
        const cap = phase.frames * harness.Machine.instructions_per_frame_cap + 1_000_000;
        var guard: u64 = 0;
        while (m.sys.frames - start < phase.frames and guard < cap) : (guard += 1) {
            log.pc = m.sys.cpu.pc;
            _ = try m.sys.step();
            const f = frame_base + (m.sys.frames - start);
            const b = if (phase.explore)
                probe.exploreButtons(@intCast(f), probe.explore_seed)
            else
                probe.bootButtons(@intCast(f));
            m.sys.bus.setKeys(b.dpad, b.buttons);
        }
        frame_base += m.sys.frames - start;
    }
    m.sys.bus.write_watch = null;

    return log.report();
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "a cartridge-RAM access the log cannot allocate marks its report incomplete" {
    // `note` allocates twice on a fresh log: the `sites` entry, then the
    // `list` slot. Failing either one used to drop the record without a word.
    inline for (.{ SaveLog, LoadLog }) |Log| {
        for ([_]usize{ 0, 1 }) |fail_index| {
            var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
            var log = Log.init(failing.allocator(), 8);
            defer log.deinit();
            log.pc = 0x4290;
            log.note(1, 0xA0C0, 0x5A);
            try testing.expect(log.incomplete);
            // The counters that need no allocation still count it.
            try testing.expectEqual(@as(usize, 1), log.distinct);
            var r = try log.report();
            defer r.deinit(failing.allocator());
            try testing.expect(r.incomplete);
        }

        var log = Log.init(testing.allocator, 1);
        defer log.deinit();
        log.note(1, 0xA0C0, 0x5A);
        log.note(1, 0xA0C1, 0x5B); // past the limit: dropped on purpose
        var r = try log.report();
        defer r.deinit(testing.allocator);
        try testing.expect(!r.incomplete);
        try testing.expectEqual(@as(usize, 2), r.distinct);
    }
}

test "a world coordinate is the screen number over the pixel offset" {
    const p: Placement = .{ .map_bank = 0x9, .warp_bank = 0x9, .screen_row = 3, .screen_col = 5, .pixel_y = 0x40, .pixel_x = 0x80 };
    try testing.expectEqual(@as(u16, 0x0580), p.worldX());
    try testing.expectEqual(@as(u16, 0x0340), p.worldY());
    // Two placements that differ only in a field `eql` does not compare are
    // still equal, and one that differs in the position is not.
    var q = p;
    q.pixel_x = 0x81;
    try testing.expect(!p.eql(q));
    try testing.expect(p.eql(p));
}

test "a map bank outside the map range is refused rather than masked" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    var m = try harness.boot(a, rom, 0);
    defer m.deinit();

    // The handler masks the operand to a nibble, so bank $19 would arrive as
    // $9 and quietly succeed at the wrong thing. Every value outside $9-$F is
    // an error here instead.
    for ([_]u8{ 0x00, 0x05, 0x08, 0x10, 0x19, 0xFF }) |bank| {
        try testing.expectError(Error.BadMapBank, spawn(&m, .{
            .map_bank = bank,
            .screen_row = 0,
            .screen_col = 0,
        }));
    }
}

test "the room harness puts Samus where it was asked to" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();
    try testing.expect(harness.alive(&m));

    var snap = try m.snapshot();
    defer snap.deinit(a);

    // Spread across banks, across the screen grid, and across the screen: a
    // harness that only worked for the boot cell would pass a single case.
    const cases = [_]Spawn{
        .{ .map_bank = 0x9, .screen_row = 0, .screen_col = 0, .pixel_y = 0x40, .pixel_x = 0x40 },
        .{ .map_bank = 0x9, .screen_row = 7, .screen_col = 6, .pixel_y = 0x80, .pixel_x = 0x80 },
        .{ .map_bank = 0xB, .screen_row = 3, .screen_col = 12, .pixel_y = 0x00, .pixel_x = 0xFF },
        .{ .map_bank = 0xE, .screen_row = 15, .screen_col = 15, .pixel_y = 0xC0, .pixel_x = 0x20 },
        .{ .map_bank = 0xF, .screen_row = 7, .screen_col = 6, .pixel_y = 0x10, .pixel_x = 0x90 },
    };

    for (cases) |c| {
        m.restore(snap);
        const got = try spawn(&m, c);
        try testing.expectEqual(c.map_bank, got.map_bank);
        try testing.expectEqual(@as(u8, c.screen_row), got.screen_row);
        try testing.expectEqual(@as(u8, c.screen_col), got.screen_col);
        try testing.expectEqual(c.pixel_y, got.pixel_y);
        try testing.expectEqual(c.pixel_x, got.pixel_x);
        try testing.expectEqual(
            (@as(u16, c.screen_col) << 8) | c.pixel_x,
            got.worldX(),
        );
    }
}

test "a spawn survives the frames that follow it" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();

    // Setting the variables is not the same as arriving. If the room does not
    // actually load, the next frames will move her somewhere else or the game
    // will transition away, and the placement read back afterwards will differ.
    // Held with no input so nothing but the game's own physics acts on her.
    const want: Spawn = .{ .map_bank = 0x9, .screen_row = 7, .screen_col = 6, .pixel_y = 0x40, .pixel_x = 0x80 };
    const placed = try spawn(&m, want);
    _ = try m.runFrames(60, .{});
    const after = placement(&m);

    try testing.expectEqual(placed.map_bank, after.map_bank);
    try testing.expectEqual(placed.screen_row, after.screen_row);
    try testing.expectEqual(placed.screen_col, after.screen_col);
    // She is allowed to fall -- there may be nothing under her -- but she must
    // still be on the screen the harness put her on.
}

test "the same request twice puts her in the same place" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();
    var snap = try m.snapshot();
    defer snap.deinit(a);

    const want: Spawn = .{ .map_bank = 0xB, .screen_row = 4, .screen_col = 9, .pixel_y = 0x30, .pixel_x = 0x70 };

    m.restore(snap);
    const first = try spawn(&m, want);
    _ = try m.runFrames(120, .{});
    const first_after = placement(&m);

    m.restore(snap);
    const second = try spawn(&m, want);
    _ = try m.runFrames(120, .{});
    const second_after = placement(&m);

    try testing.expect(first.eql(second));
    // And two minutes of physics from the same start produce the same end,
    // which is the property the oracle's frame-for-frame comparison rests on.
    try testing.expect(first_after.eql(second_after));
}


test "the opening of the game does not write a save record" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // **This is the test that pins a deferral**, and it is here so the
    // deferral has evidence behind it rather than a shrug.
    //
    // `01-requirements` asks the room harness to set equipment, beam, energy,
    // missiles and the Metroid count as well as a position, and suggests doing
    // it by synthesizing a save record. `watchSave` is the mechanical way to
    // learn that record's layout: watch the game write one, and every field's
    // offset and the routine that copies it fall out together. Ninety seconds
    // of booting and directed play write **one byte** of cartridge RAM, the
    // file counter at $A0C0 that $02BA reads back at reset. No record, because
    // the game only writes one at a save station and no amount of the
    // exploration schedule reaches a save station.
    //
    // So the harness ships the *mechanism* -- `Spawn.writes` sets any address
    // to any value at spawn time -- and not the field addresses, because
    // guessing them would be exactly the transcription the requirement forbids.
    // Step 15's TAS input stream is what closes this: a tool-assisted run of
    // Metroid II saves, and `watchSave` pointed at it will name every field.
    //
    // If this test ever fails because a record *did* get written, that is not a
    // regression. It means the schedule reached a save station and the addresses
    // are now there for the taking.
    var r = try watchSave(a, rom, 30, 60, 64);
    defer r.deinit(a);

    try testing.expect(r.distinct <= 1);
    if (r.distinct == 1) {
        try testing.expectEqual(@as(u16, 0xA0C0), r.low);
        try testing.expectEqual(@as(u16, 0xA0C0), r.high);
    }
}

test "an arbitrary write lands with the spawn" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();

    // The loadout mechanism, exercised against an address whose meaning is
    // established: the solidity threshold `TryStanding` compares against. It
    // stands in for the equipment fields until those have addresses, and it
    // proves the same thing about the plumbing -- that a value set at spawn
    // time is there when the game starts running.
    const threshold_addr: u16 = 0xD056;
    const p = try spawn(&m, .{
        .map_bank = 0x9,
        .screen_row = 7,
        .screen_col = 6,
        .writes = &.{.{ .addr = threshold_addr, .value = 0x5A }},
    });
    try testing.expectEqual(@as(u8, 0x9), p.map_bank);
    try testing.expectEqual(@as(u8, 0x5A), m.read(threshold_addr));
}

test "the two room harnesses agree on where a position is" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();
    var snap = try m.snapshot();
    defer snap.deinit(a);

    // **The precondition Step 15 rests on.** A frame-for-frame comparator has
    // to put both machines on the same pixel of the same screen at frame 0, and
    // "the same" has to mean something checkable. It does: a position is a
    // 16-bit world coordinate per axis on both sides, screen number over pixel
    // offset, and the two are built by completely different routes -- the Game
    // Boy's out of what the `WARP` handler left in $FFC9/$FFC8 and $FFCB/$FFCA
    // after actually running, the SNES's out of the boot cell by arithmetic in
    // `snes_screen.samusAt`. This asserts they land on the same number.
    //
    // Deliberately not a tautology: the Game Boy side is *read back out of the
    // machine* after the warp ran, not echoed from the request. If the handler
    // interpreted the nibbles differently from the way the SNES side packs a
    // cell -- row and column the other way round, say -- this is what would
    // catch it.
    const cases = [_]struct { bank: u8, row: u4, col: u4, px: u8, py: u8 }{
        .{ .bank = 0x9, .row = 0, .col = 0, .px = 0x80, .py = 0x80 },
        .{ .bank = 0x9, .row = 7, .col = 6, .px = 0x00, .py = 0xFF },
        .{ .bank = 0xB, .row = 3, .col = 12, .px = 0x40, .py = 0x10 },
        .{ .bank = 0xE, .row = 15, .col = 15, .px = 0xFF, .py = 0x00 },
        .{ .bank = 0xF, .row = 9, .col = 1, .px = 0x33, .py = 0xCC },
    };

    for (cases) |c| {
        m.restore(snap);
        const gb = try spawn(&m, .{
            .map_bank = c.bank,
            .screen_row = c.row,
            .screen_col = c.col,
            .pixel_x = c.px,
            .pixel_y = c.py,
        });

        // The SNES side names a screen by a cell, `row * 16 + col`, which is
        // the same packing the map grid uses on both machines.
        const cell: u8 = (@as(u8, c.row) << 4) | @as(u8, c.col);
        const snes = snes_screen.samusAt(cell, c.px, c.py);

        try testing.expectEqual(snes.x, gb.worldX());
        try testing.expectEqual(snes.y, gb.worldY());
        // And the bank numbering: the SNES boot record holds a map *index*
        // counted from the first map bank, and the Game Boy holds the bank.
        try testing.expectEqual(c.bank - map_bank_first, gb.map_bank - map_bank_first);
    }
}

test "the default SNES start is a position the Game Boy harness can be asked for" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();

    // The boot record's default is the middle of the boot cell. Whatever cell
    // `chooseBoot` picks, asking the Game Boy for that cell's middle must
    // produce the same coordinates the injector writes into the cart -- which
    // is the case Step 15 will actually use first, since the default is where
    // both machines start today.
    const boot = try snes_screen.chooseBoot(a, rom);
    const want = snes_screen.samusStart(boot.cell);
    try testing.expectEqual(want.x, boot.samus_x);
    try testing.expectEqual(want.y, boot.samus_y);

    const gb = try spawn(&m, .{
        .map_bank = map_bank_first + boot.map_index,
        .screen_row = @truncate(boot.cell >> 4),
        .screen_col = @truncate(boot.cell & 0x0F),
        .pixel_x = @truncate(want.x),
        .pixel_y = @truncate(want.y),
    });
    try testing.expectEqual(boot.samus_x, gb.worldX());
    try testing.expectEqual(boot.samus_y, gb.worldY());
}

test "the harness sets the loadout by name, and the game keeps it" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try harness.boot(a, rom, harness.boot_seconds_default);
    defer m.deinit();

    // Values the game would never hand a new file, so a passing check cannot
    // be the default loadout agreeing with the request by accident: a new file
    // gets $99 energy, $30 missiles and $47 Metroids.
    const want: Loadout = .{
        .energy = 0x42,
        .missiles = 0x11,
        .missile_capacity = 0x63,
        .metroid_count_real = 0x21,
        .metroid_count_displayed = 0x22,
    };
    _ = try spawn(&m, .{
        .map_bank = 0x9,
        .screen_row = 7,
        .screen_col = 6,
        .pixel_y = 0x40,
        .pixel_x = 0x80,
        .loadout = want,
    });

    // Read back through `save.fields` rather than through the same constants
    // `apply` used, so the two sides cannot agree by sharing a typo.
    inline for (@typeInfo(Loadout).@"struct".fields) |f| {
        const addr = comptime Loadout.addrOf(f.name);
        try testing.expectEqual(@field(want, f.name).?, m.read(addr));
    }

    // And they survive the frames that follow, which is what says these are
    // the variables the game plays from rather than a copy it overwrites.
    _ = try m.runFrames(60, .{});
    try testing.expectEqual(@as(u8, 0x11), m.read(comptime Loadout.addrOf("missiles")));
    try testing.expectEqual(@as(u8, 0x21), m.read(comptime Loadout.addrOf("metroid_count_real")));
}

test "the boot schedule leaves the game paused, and bootIntoPlay does not" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // The schedule every other test in this repository uses. Start is Metroid
    // II's pause button as well as its start button, and thirty seconds of
    // tapping it lands on the wrong parity.
    var paused = try harness.boot(a, rom, harness.boot_seconds_default);
    defer paused.deinit();
    try testing.expect(harness.alive(&paused)); // it draws, which is why nobody noticed
    try testing.expect(!try playing(&paused));

    var live = try bootIntoPlay(a, rom);
    defer live.deinit();
    try testing.expect(try playing(&live));
}

test "a spawn into a playing game moves when it is told to" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try bootIntoPlay(a, rom);
    defer m.deinit();

    const placed = try spawn(&m, .{
        .map_bank = 0x9,
        .screen_row = 3,
        .screen_col = 8,
        .pixel_x = 0x80,
        .pixel_y = 0x80,
    });
    try testing.expect(try playing(&m));

    // Right held. The whole point of the harness is that the game then plays
    // from where it was put, and "plays" means she moves.
    var right: probe.Buttons = .{};
    right.dpad &= ~@as(u4, 0b0001);
    _ = try m.runFrames(60, right);
    const after = placement(&m);
    try testing.expect(after.worldX() != placed.worldX());
}

test "the door-script constants are the ones the probe found" {
    // `door_interp` and `door_index_addr` are duplicated from `gb/probe.zig`
    // rather than imported, because that module is the emulator and is not
    // allowed to know Metroid II's layout. This is the seam where the two
    // copies are checked against each other.
    try testing.expectEqual(probe.interp_entry, door_interp);
    try testing.expectEqual(probe.door_index_addr, door_index_addr);
    // The direction byte is the same variable in both, and in the handler.
    try testing.expectEqual(probe.door_direction_addr, direction_addr);
}

test "a room is thirty-two columns and a warp draws six of them" {
    // The arithmetic behind `drawRoom`, stated so a change to either constant
    // has to face it. A screen is 16x16 metatiles of 2x2 tiles, which is the
    // background map exactly; `draw_column` draws one metatile column, so the
    // whole screen is `columns_per_screen` of them and the warp handler's three
    // are three.
    try testing.expectEqual(@as(usize, 32), columns_per_screen * 2);
    try testing.expectEqual(@as(usize, 256), columns_per_screen * metatile_pixels);
}

// ---- The entity foundation's fixture, Step 9 -------------------------------
//
// **The oracle here is the running game, not our own arithmetic.** `entity.zig`
// says a cell's spawn list holds a record with a given number, type and
// position; these put the original in that room, scroll its camera, and read
// what *it* put in its own slot array. A reader with the record stride or the
// field order wrong would still parse a plausible-looking list, and only the
// game can say the list is the right one.

/// $C600, the sixteen $20-byte enemy slots, and $C500, the 128 spawn flags.
/// From M2RoS `SRC/ram/wram.asm`; `engine/main.asm` mirrors both layouts.
pub const enemy_slots_addr: u16 = 0xC600;
pub const enemy_slot_bytes: u16 = 0x20;
pub const enemy_slot_count: u16 = 16;
pub const spawn_flags_addr: u16 = 0xC500;

/// $C44B, `saveLoadSpawnFlagsRequest`. A real transition sets it (out of
/// `doorExitStatus`, 00:$0C83) and the enemy pass services it by refilling the
/// unsaved spawn flags with $FF. **The `WARP` lever this harness pulls does not
/// go through the interpreter**, so nothing sets it and the room would be
/// entered holding the previous room's flags -- which is exactly the state that
/// stops a record loading, since the walk only loads a flag of $FE or above.
pub const spawn_reload_addr: u16 = 0xC44B;

/// One slot, in the fields Step 9 fills. The AI pointer and the header's
/// interior are not named: what this fixture is about is whether the *record*
/// reached the slot.
pub const Slot = struct {
    status: u8,
    y: u8,
    x: u8,
    sprite: u8,
    y_screen: u8,
    x_screen: u8,
    flag: u8,
    number: u8,
};

pub fn slotAt(m: *harness.Machine, i: u16) Slot {
    const base = enemy_slots_addr + i * enemy_slot_bytes;
    return .{
        .status = m.read(base + 0x00),
        .y = m.read(base + 0x01),
        .x = m.read(base + 0x02),
        .sprite = m.read(base + 0x03),
        .y_screen = m.read(base + 0x0F),
        .x_screen = m.read(base + 0x10),
        .flag = m.read(base + 0x1C),
        .number = m.read(base + 0x1D),
    };
}

/// Every slot that is not empty, in slot order.
pub fn liveSlots(allocator: std.mem.Allocator, m: *harness.Machine) ![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    errdefer out.deinit(allocator);
    for (0..enemy_slot_count) |i| {
        const s = slotAt(m, @intCast(i));
        if (s.status == 0xFF) continue;
        try out.append(allocator, s);
    }
    return out.toOwnedSlice(allocator);
}

/// The spawn records `src/entity.zig` reads for one cell.
fn recordsFor(allocator: std.mem.Allocator, rom: []const u8, bank: u8, cell: u8) ![]entity.Spawn {
    const data_e = offsets.find("enemy_data") orelse return error.Missing;
    const lists = try entity.parseSpawnLists(
        allocator,
        rom[data_e.romOffset()..data_e.romEnd()],
        data_e.gb_addr,
    );
    defer entity.freeSpawnLists(allocator, lists);
    const index = (@as(usize, bank) - 9) * entity.screens_per_bank + cell;
    return allocator.dupe(entity.Spawn, lists[index].spawns);
}

/// The door `screens.assign` pairs with a cell, so the room is *loaded* rather
/// than merely arrived at -- without one there is no collision data and Samus
/// falls through the floor for as long as the fixture runs.
fn doorFor(allocator: std.mem.Allocator, rom: []const u8, bank: u8, cell: u8) !?u16 {
    var asg = try screens.assign(allocator, rom);
    defer asg.deinit(allocator);
    for (asg.cells) |c| {
        if (c.bank != bank) continue;
        if ((@as(u8, c.y) << 4 | @as(u8, c.x)) != cell) continue;
        return if (c.choice) |ch| ch.door_index else null;
    }
    return null;
}

/// Drag the camera across a screen a pixel a frame and collect every record the
/// game loads on the way.
///
/// **The camera is driven rather than walked into place, and that is the whole
/// reason this fixture works.** 03:$4014 does nothing unless the scroll has
/// moved since two passes ago, and it loads a record only as one of the four
/// camera edges crosses that record's own rounded coordinate -- so which
/// direction and how far is a property of the room's geometry, not of the data
/// under test. Measured 2026-09-08: 240 frames of held input in this room load
/// nothing at all, because there is nowhere for her to walk. Writing the camera
/// is the same class of lever as the `WARP` write this harness already makes,
/// and it exercises exactly the mechanism in question.
fn sweepCameraX(allocator: std.mem.Allocator, m: *harness.Machine) ![]Slot {
    var seen: std.ArrayList(Slot) = .empty;
    errdefer seen.deinit(allocator);
    var px: u16 = 0;
    while (px < 0x100) : (px += 1) {
        const v: u8 = @intCast(px);
        m.write(camera_pixel_x_addr, v);
        m.write(samus_pixel_x_addr, v);
        _ = try m.runFrames(1, .{});
        const live = try liveSlots(allocator, m);
        defer allocator.free(live);
        for (live) |s| {
            for (seen.items) |known| {
                if (known.number == s.number and known.sprite == s.sprite) break;
            } else try seen.append(allocator, s);
        }
    }
    return seen.toOwnedSlice(allocator);
}

test "every enemy the game loads is one the spawn records describe" {
    // Map bank $F, row 7, column 6. **Not the oracle segment's cell**, whatever
    // the plan's B4 note says -- see the test below.
    //
    // What loads here is the record `entity.zig` places in the screen to the
    // *left*, cell $75, because the vertical walk reads the left screen's list
    // before the right one's. That is the mechanism working, not an index being
    // off: the assertions below require the pair to be exactly that record and
    // to be absent from every neighbouring cell.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try spawn(&m, .{
        .map_bank = 0x0F,
        .screen_row = 7,
        .screen_col = 6,
        .pixel_y = 0x80,
        .pixel_x = 0x80,
        .door_index = try doorFor(a, rom, 0x0F, 0x76),
    });
    m.write(spawn_reload_addr, 0x02);

    const loaded = try sweepCameraX(a, &m);
    defer a.free(loaded);
    try testing.expect(loaded.len != 0);

    // Every pair the game produced has to be a record we can point at, in one
    // of the three screens the walk is allowed to read from a camera standing
    // in $76: this one and its two horizontal neighbours.
    for (loaded) |s| {
        var matched = false;
        for ([_]u8{ 0x75, 0x76, 0x77 }) |cell| {
            const list = try recordsFor(a, rom, 0x0F, cell);
            defer a.free(list);
            for (list) |r| {
                if (r.number == s.number and r.sprite == s.sprite) matched = true;
            }
        }
        testing.expect(matched) catch |e| {
            std.debug.print("slot number {d} sprite ${X:0>2} is in no neighbouring cell's records\n", .{ s.number, s.sprite });
            return e;
        };
    }

    // And the specific one, so the test cannot pass by loading nothing
    // interesting: spawn 14, sprite $9B, which the reader places at cell $75.
    var found: ?Slot = null;
    for (loaded) |s| {
        if (s.number == 14) found = s;
    }
    const got = found orelse return error.EnemyNeverLoaded;
    try testing.expectEqual(@as(u8, 0x9B), got.sprite);

    const left = try recordsFor(a, rom, 0x0F, 0x75);
    defer a.free(left);
    var in_left = false;
    for (left) |r| {
        if (r.number == 14 and r.sprite == 0x9B) in_left = true;
    }
    try testing.expect(in_left);

    // The flag array agrees with the slot, which is the write-back at the tail
    // of 02:$4421 -- the mechanism `SlotFlagOut` ports. Read from the slot
    // rather than from the sweep's copy, because the enemy has AI and may have
    // been deactivated by the time the sweep ended.
    for (0..enemy_slot_count) |i| {
        const s = slotAt(&m, @intCast(i));
        if (s.status == 0xFF) continue;
        try testing.expectEqual(s.flag, m.read(spawn_flags_addr + s.number));
    }
}

test "the loaded record is in the cell the index arithmetic names and in no neighbour" {
    // The index on its own, which is where an off-by-one hides best:
    // `(bank - 9) * 256 + (row << 4) + col`, the same expression `SpawnListAt`
    // computes in the engine. The fixture above could still pass with the index
    // one cell out if a neighbour happened to carry the same record, so this
    // requires the neighbours to disagree -- the old wrong answer made to fail.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const here = try recordsFor(a, rom, 0x0F, 0x75);
    defer a.free(here);
    try testing.expectEqual(@as(usize, 1), here.len);
    try testing.expectEqual(@as(u8, 14), here[0].number);
    try testing.expectEqual(@as(u8, 0x9B), here[0].sprite);
    try testing.expectEqual(@as(u8, 0xD0), here[0].x);
    try testing.expectEqual(@as(u8, 0xB8), here[0].y);

    // One cell either side, one row either side, and the same cell in the
    // neighbouring bank: none of them holds spawn 14, so none of the five ways
    // the index could be wrong would have produced the answer the game gave.
    for ([_]struct { bank: u8, cell: u8 }{
        .{ .bank = 0x0F, .cell = 0x74 },
        .{ .bank = 0x0F, .cell = 0x76 },
        .{ .bank = 0x0F, .cell = 0x65 },
        .{ .bank = 0x0F, .cell = 0x85 },
        .{ .bank = 0x0E, .cell = 0x75 },
    }) |c| {
        const list = try recordsFor(a, rom, c.bank, c.cell);
        defer a.free(list);
        for (list) |r| try testing.expect(r.number != 14);
    }

    // And cell $76's own record, which the plan's B4 note quotes, so a change
    // to the reader that moved it would be caught here rather than in prose.
    const right = try recordsFor(a, rom, 0x0F, 0x76);
    defer a.free(right);
    try testing.expectEqual(@as(usize, 1), right.len);
    try testing.expectEqual(@as(u8, 0x0F), right[0].number);
    try testing.expectEqual(@as(u8, 0x9D), right[0].sprite);
    try testing.expectEqual(@as(u8, 0x38), right[0].x);
    try testing.expectEqual(@as(u8, 0xB8), right[0].y);
}

test "the oracle segment's own cell has no enemy on it" {
    // Written down as a fixture because the plan's B4 note says otherwise, and
    // a wrong premise that lives only in prose is one the next turn re-derives
    // from scratch. `oracle.chooseStart` picks map index 0 -- bank $9 -- cell
    // $38, which the gate prints on every run; that cell's spawn list is empty.
    // **That is why the segment rung could not move when the entity foundation
    // landed**, and the note's `$0F`/`$76` is a different room entirely.
    //
    // Its left neighbour is not empty, and that is worth having too: the
    // segment rolls left for 220 frames, so the reference does load enemies
    // partway through the very stretch the rung grades -- and the rung still
    // holds, because it compares position, camera and pose, and an enemy the
    // port neither draws nor moves touches none of the three.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const segment_cell = try recordsFor(a, rom, 0x09, 0x38);
    defer a.free(segment_cell);
    try testing.expectEqual(@as(usize, 0), segment_cell.len);

    const westward = try recordsFor(a, rom, 0x09, 0x37);
    defer a.free(westward);
    try testing.expectEqual(@as(usize, 2), westward.len);
}

// ---- B4b's fixture, Step 10 ------------------------------------------------

/// The hitbox record and the damage byte an enemy id resolves to, read the way
/// `LoadEnemyBox` and `EnemyDamageFor` read them: through the *converted*
/// pointer table, not through the Game Boy's.
fn hitboxFor(allocator: std.mem.Allocator, rom: []const u8, id: u8) !?entity.Hitbox {
    const pe = offsets.find("enemy_hitbox_pointers") orelse return error.Missing;
    const be = offsets.find("enemy_hitboxes") orelse return error.Missing;
    const ptrs = rom[pe.romOffset()..pe.romEnd()];
    const boxes = try entity.parseHitboxes(allocator, rom[be.romOffset()..be.romEnd()]);
    defer allocator.free(boxes);
    const gb_addr: u16 = @as(u16, ptrs[@as(usize, id) * 2]) |
        (@as(u16, ptrs[@as(usize, id) * 2 + 1]) << 8);
    if (gb_addr < be.gb_addr or gb_addr >= be.gb_addr + be.size) return null;
    const rel = gb_addr - be.gb_addr;
    if (rel % entity.hitbox_bytes != 0) return null;
    return boxes[rel / entity.hitbox_bytes];
}

test "the enemy the segment is hit by has the hitbox and damage the ROM gives it" {
    // **The numbers this fixture pins are the ones B4b's port arrives at, and
    // they were measured on the running Game Boy before the port had them**:
    // the segment's knockback takes health $99 to $84, which is $15 in BCD, and
    // $15 is what `enemy_damage` holds for sprite $16. A damage table read one
    // byte out would give a different subtraction and the segment would tell
    // us; this says which byte the segment was about.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const dmg_e = offsets.find("enemy_damage") orelse return error.Missing;
    const dmg = rom[dmg_e.romOffset()..dmg_e.romEnd()];
    try testing.expectEqual(entity.enemy_id_space, dmg.len);

    // The Senjoo, which is what reaches Samus at reference frame 701.
    try testing.expectEqual(@as(u8, 0x15), dmg[0x16]);
    const senjoo = (try hitboxFor(a, rom, 0x16)) orelse return error.Missing;
    try testing.expectEqual(entity.Hitbox{ .a = -8, .b = 7, .c = -12, .d = 11 }, senjoo);

    // And the small bug in the room the ball rolls into, which is the other AI
    // the segment dispatches. A narrower box and a third of the damage.
    try testing.expectEqual(@as(u8, 0x05), dmg[0x12]);
    const bug = (try hitboxFor(a, rom, 0x12)) orelse return error.Missing;
    try testing.expectEqual(entity.Hitbox{ .a = -4, .b = 3, .c = -8, .d = 7 }, bug);

    // The four cases `CollideResolve` branches on, as a property of the table
    // rather than of two ids: $FF solid, $FE draining, $00 intangible and
    // anything else BCD health. All four occur, which is what makes porting all
    // four branches something other than defensive programming.
    var solid: usize = 0;
    var drain: usize = 0;
    var free: usize = 0;
    var hurts: usize = 0;
    for (dmg) |d| switch (d) {
        0xFF => solid += 1,
        0xFE => drain += 1,
        0x00 => free += 1,
        else => hurts += 1,
    };
    try testing.expect(solid != 0);
    try testing.expect(drain != 0);
    try testing.expect(free != 0);
    try testing.expect(hurts != 0);
    try testing.expectEqual(entity.enemy_id_space, solid + drain + free + hurts);

    // The dead pointer the conversion refuses, as a fact about this cartridge:
    // exactly one id names no record, and it is $9A.
    var dead: usize = 0;
    for (0..entity.enemy_id_space) |i| {
        if ((try hitboxFor(a, rom, @intCast(i))) == null) dead += 1;
    }
    try testing.expectEqual(@as(usize, 1), dead);
    try testing.expect((try hitboxFor(a, rom, 0x9A)) == null);
}

// ---- The round trip: save, die, reload (Step 15d) --------------------------

/// `saveContactFlag`. Set by both bottom probes of the collision when Samus is
/// standing on a save station's tile, cleared by a door's transfer and by the
/// station itself; `residue.zig` carries the whole list.
pub const save_contact_addr: u16 = 0xD07D;
/// `samusCurHealth`, the energy the record carries at offset 32, and the
/// displayed copy the death test reads. Both by name from `save.fields`.
pub const cur_health_addr: u16 = 0xD051;
pub const disp_health_addr: u16 = 0xD084;

/// The collision byte's save-station bit, `BIT 7,A` at both probes of
/// `collision_samusBottom` (00:$1F4F and 00:$1F92). `correspond.zig` derives it
/// from those two instructions rather than from a listing, and the engine's
/// `!BLOCK_SAVE` is the same bit.
pub const block_save: u8 = 0x80;

/// A tile id a collision table calls a save station, with the table it is in.
///
/// **A new game cannot stand on a station, and that is the ROM's doing.** The
/// eight tables are $100 bytes each in bank 8; scanned for bit 7, `caveFirst`
/// has ids 16-19, `plantBubbles` and `lavaCaves` four each and `ruinsInside`
/// six -- and `surface`, which a new game's record names, has none at all. Which
/// is why the recording's five saves are all in `caveFirst` rooms, and why the
/// scenario below cannot simply start the game and look down.
pub const Station = struct { collision_src: u16, tile: u8 };

pub fn findStationTile(rom: []const u8) ?Station {
    for (offsets.entries) |e| {
        if (e.kind != .collision) continue;
        if (e.romEnd() > rom.len) continue;
        for (rom[e.romOffset()..e.romEnd()], 0..) |b, id| {
            if (b & block_save != 0) return .{ .collision_src = e.gb_addr, .tile = @intCast(id) };
        }
    }
    return null;
}

/// Put Samus in contact with a save station.
///
/// **This sets the flag the collision sets; it does not walk her onto a tile,
/// and it is not evidence that the collision would.** Both bottom probes end
/// `LD A,$FF / LD ($D07D),A` (00:$1F53 and 00:$1F96), and that store is what is
/// reproduced here. Everything after it is the game's: the cooldown, the
/// window, Start's rising edge, the writer, the death, the title's slot check
/// and the load.
///
/// **Why not the real thing.** Two routes were built and neither survives
/// contact with the harness, and the reasons are worth keeping because they are
/// the map's and the hardware's rather than ours:
///
///   * *Walk to `$F:$01`.* A station's door script is `ITEM $0; END` -- it
///     names no metatile or collision table, because in play she arrives
///     through a door that already loaded them -- so `spawn` with it leaves the
///     previous room's tables mapped and the collision reads the wrong bytes.
///     `screens.assign`'s answer for the cell is door 085, which is `ITEM $0;
///     WARP $F,$06`: another station script, and run out of context it does not
///     return at all.
///   * *Lay a station under her*, which is what Step 15a's phase 26 does on the
///     cart. On the Game Boy the tile has to go into video RAM, which the PPU
///     locks outside vblank, so `m.write` drops it silently; written into the
///     array instead it lands, and `getTilemapAddress` (00:$22BC) bases at
///     `$97E0` with a `$0400` page bit from `$C219`, so the probe can read
///     either map; filled across both, the streamer draws over it within a
///     frame. Refilling every frame and walking her still leaves the pose at
///     `$00`.
///
/// **What grades the contact is the cart, and it already does.** Step 15a's
/// phase 26 lays a station from the loaded collision table, stands her on it
/// and fails on code 240 if the contact does not rise -- and it showed the
/// cart failing before the collision's two bit-7 tests were ported. So the
/// contact has a fixture that fails when it is removed; this function is not
/// pretending to be a second one.
pub fn contactStation(m: *harness.Machine) void {
    m.write(save_contact_addr, 0xFF);
}

/// Press Start on a station and hand back the record the game wrote.
///
/// The save is the game's: Start's rising edge on frame N sets game mode $09,
/// and the writer stores the record on N+1 (`docs/slice.md`, five saves, one
/// shape). Nothing here writes cartridge RAM.
pub fn saveHere(m: *harness.Machine) ![save.record_len]u8 {
    if (m.read(save_contact_addr) != 0xFF) return error.NotOnAStation;

    var start: probe.Buttons = .{};
    start.buttons &= ~@as(u4, 0b1000);
    _ = try m.runFrames(1, start);
    _ = try m.runFrames(8, .{});

    var out: [save.record_len]u8 = undefined;
    @memcpy(&out, m.ram[0..save.record_len]);
    if (!std.mem.eql(u8, out[0..save.magic_len], &save.magic)) return error.NoRecordWritten;
    return out;
}

test "the round trip: one unit of energy, a save, a death, and the record comes back" {
    // **B7's scenario, the one James named**: one unit of energy, a save at a
    // station, the damage that kills her, and the game loading back what the
    // record said — not what happened to survive in RAM, which after a reboot
    // is nothing.
    //
    // The energy is what makes it an argument. She saves holding $01, dies
    // holding $00, and the reload has to bring back $01: neither a load that
    // read the live variables nor one that read a record it had not written can
    // produce that number.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try bootIntoPlay(a, rom);
    defer m.deinit();

    // The tileset the game loaded for itself, and the station tile in it.
    const start_record = save.initial(rom) orelse return error.NoInitialRecord;
    const station = findStationTile(rom) orelse return error.NoStationTile;
    // The ROM's own answer to "could she have saved where she started": no.
    try testing.expect(station.collision_src != start_record.collision_src);

    const one_unit: u8 = 0x01;
    m.write(cur_health_addr, one_unit);
    m.write(cur_health_addr + 1, 0);
    m.write(disp_health_addr, one_unit);
    m.write(disp_health_addr + 1, 0);
    contactStation(&m);
    try testing.expectEqual(one_unit, m.read(cur_health_addr));

    // The save is the game's: nothing here writes cartridge RAM, and
    // `watchSave`'s own watcher is what says so.
    var log = SaveLog.init(a, 256);
    defer log.deinit();
    log.attach(&m);
    const record = try saveHere(&m);
    m.sys.bus.write_watch = null;
    var report = try log.report();
    defer report.deinit(a);

    // Every byte of the record came from the game, from inside its own writer.
    // Where the save landed, by the watcher rather than by us: the slot at the
    // bottom of the window and the saved half of the spawn flags at `$B000`.
    // The per-write program counter is not asserted on -- `SaveLog` takes it
    // from the caller before each step and `runFrames` does not supply one, so
    // every row here reads `$0000`. `watchSave`, which steps itself, is where
    // the writing site is pinned, and `save.zig` pins the routine.
    try testing.expectEqual(@as(u16, save.slot_base), report.low);
    try testing.expect(report.high >= 0xB000);
    try testing.expect(report.distinct >= save.record_len);

    const want = save.parseInitial(record[save.magic_len..]) orelse return error.BadRecord;
    try testing.expectEqual(one_unit, @as(u8, @truncate(want.health)));
    try testing.expectEqual(m.read(map_bank_addr), want.level_bank);

    // The damage. One unit of energy and anything at all takes her to zero,
    // which is what 00:$04EC tests; `death.measure` is the lever Step 15c
    // graded the death with, and the death itself is that step's business.
    _ = try death.measure(&m, death.start_press);
    try testing.expectEqual(@as(u8, 0), m.read(cur_health_addr));

    // And back. The title reads the slot the game wrote — nothing here put it
    // there — and the load has to restore the record's every field.
    try testing.expectEqual(death.on_reload, try death.measureReload(&m, 600));

    try testing.expectEqual(want.level_bank, m.read(map_bank_addr));
    try testing.expectEqual(one_unit, m.read(cur_health_addr));
    try testing.expectEqual(want.samus_x, m.readWord(0xFFC2));
    try testing.expectEqual(want.samus_y, m.readWord(0xFFC0));
    try testing.expectEqual(want.metroid_count_real, m.read(0xD089));
    try testing.expectEqual(want.metroid_count_displayed, m.read(0xD09A));

    // **And the reload is shown to be reading the record.** Perturb the energy
    // field in cartridge RAM, die again, and the value that comes back is the
    // perturbed one. Without this, the two lines above would pass just as well
    // on a load that ignored the slot and left a new game's numbers standing.
    const perturbed: u8 = 0x42;
    try testing.expect(perturbed != one_unit);
    for (save.fields) |f| {
        if (std.mem.eql(u8, f.name, "energy")) m.ram[f.offset] = perturbed;
    }
    _ = try death.measure(&m, death.start_press);
    try testing.expectEqual(death.on_reload, try death.measureReload(&m, 600));
    try testing.expectEqual(perturbed, m.read(cur_health_addr));
}

test "the loaded record's Metroid count is the saved one, not a new game's" {
    // `metroidCountReal` is the field the slice's progression hangs on, and the
    // one a reload is most likely to get wrong: a load that fell back to the
    // new game's record would bring back $47 and nothing else in the state
    // would look out of place. So it is asserted against a count that is not
    // the new game's, saved deliberately.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var m = try bootIntoPlay(a, rom);
    defer m.deinit();

    const start_record = save.initial(rom) orelse return error.NoInitialRecord;
    // One Alpha down, which is what the recording's own first save carries and
    // what the cart's scenario reaches by killing one.
    const after_a_kill: u8 = 0x46;
    try testing.expect(after_a_kill != start_record.metroid_count_real);
    const loadout: Loadout = .{ .metroid_count_real = after_a_kill, .metroid_count_displayed = 0x38, .energy = 0x01 };
    loadout.apply(&m);

    contactStation(&m);
    const record = try saveHere(&m);
    const want = save.parseInitial(record[save.magic_len..]) orelse return error.BadRecord;
    try testing.expectEqual(after_a_kill, want.metroid_count_real);

    _ = try death.measure(&m, death.start_press);
    try testing.expectEqual(death.on_reload, try death.measureReload(&m, 600));

    try testing.expectEqual(after_a_kill, m.read(0xD089));
    try testing.expect(m.read(0xD089) != start_record.metroid_count_real);
}

// ---- Behind the background: a per-screen bit, not a per-part one ----------

/// `samus_onscreenYPos` and `samus_onscreenXPos`, which `drawSamus_common`
/// (01:$4DDF) stores beside the sprite position it hands `drawSamusSprite`.
const samus_onscreen_y_addr: u16 = 0xD03B;
const samus_onscreen_x_addr: u16 = 0xD03C;

/// Samus's OAM entries after a frame: the ones within a sprite's reach of the
/// origin `drawSamus_common` computed. Returns how many there are and how many
/// carry bit 7, OBJ-behind-BG-colours-1-3.
const Behind = struct { parts: usize, behind: usize };

fn samusBehind(m: *harness.Machine) Behind {
    const sy = m.read(samus_onscreen_y_addr);
    const sx = m.read(samus_onscreen_x_addr);
    var r: Behind = .{ .parts = 0, .behind = 0 };
    var i: u16 = 0;
    while (i < 0xA0) : (i += 4) {
        const y = m.read(0xFE00 + i);
        const x = m.read(0xFE00 + i + 1);
        if (y == 0) continue;
        // Wrapping: just after a spawn the camera has not caught up, and her
        // parts sit across the 256 boundary from the origin.
        const dy: i8 = @bitCast(y -% sy);
        const dx: i8 = @bitCast(x -% sx);
        if (dy < -40 or dy > 16 or dx < -24 or dx > 24) continue;
        r.parts += 1;
        if (m.read(0xFE00 + i + 3) & 0x80 != 0) r.behind += 1;
    }
    return r;
}

test "Samus goes behind the background on the screens whose transition word has bit 11" {
    // `loadScreenSpritePriorityBit` (00:$3ED5) reads the high byte of the
    // transition word at $4300 + 2*(screen_y*16 + screen_x) for *Samus's*
    // screen, and stores its bit 3 inverted in $D057. `drawSamusSprite`
    // (01:$4BA1) sets OAM bit 7 on every part it writes while $D057 is 0, and
    // `drawSamus_common` zeroes $D057 again at 01:$4E18. So whether she goes
    // behind is decided per screen, for every part at once -- and a check on
    // the metasprite data's own bit 7 (sprites.zig) can never see it.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const f = offsets.find("mapF_transition_indexes").?;
    const ship_cell: usize = 0x76;
    const hi = f.romOffset() + ship_cell * 2 + 1;
    try testing.expect(rom[hi] & 0x08 != 0);

    {
        var m = try bootIntoPlay(a, rom);
        defer m.deinit();
        const p = placement(&m);
        try testing.expectEqual(@as(u8, 0xF), p.map_bank);
        try testing.expectEqual(@as(u8, 7), p.screen_row);
        try testing.expectEqual(@as(u8, 6), p.screen_col);
        _ = try m.runFrames(2, .{});
        const at_ship = samusBehind(&m);
        try testing.expect(at_ship.parts >= 4);
        try testing.expectEqual(at_ship.parts, at_ship.behind);

        // A screen whose word has the bit clear: bank 9 has none set.
        _ = try spawn(&m, .{ .map_bank = 0x9, .screen_row = 7, .screen_col = 6, .pixel_y = 0x40, .pixel_x = 0x80 });
        _ = try m.runFrames(60, .{});
        const clear = samusBehind(&m);
        try testing.expect(clear.parts >= 4);
        try testing.expectEqual(@as(usize, 0), clear.behind);
    }

    // The bit is the lever and not something else about the ship: with it
    // cleared in a copy of the ROM, she stands at the ship in front.
    const patched = try a.dupe(u8, rom);
    defer a.free(patched);
    patched[hi] &= ~@as(u8, 0x08);
    var m = try bootIntoPlay(a, patched);
    defer m.deinit();
    _ = try m.runFrames(2, .{});
    const unset = samusBehind(&m);
    try testing.expect(unset.parts >= 4);
    try testing.expectEqual(@as(usize, 0), unset.behind);
}
