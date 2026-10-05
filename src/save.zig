//! The save record: what the game keeps across a save, and where each field
//! lives while the game is running.
//!
//! Step 14 shipped `room.Spawn`'s loadout as an unnamed address/value list,
//! because the mechanical way to name the fields is to watch the game write a
//! record and ninety seconds of random input never reaches a save station.
//! Step 15's plan expected a tool-assisted run to reach one. It does not
//! either -- both published runs replay for minutes and write exactly one byte
//! of cartridge RAM, the file counter -- so this is the third route, and it is
//! the shortest of the three: **find the routine that writes the record and
//! read the record off it**.
//!
//! ## How it was found
//!
//! Not by looking for something called "save". `room.LoadLog` boots the game
//! and reports every cartridge-RAM access; a fresh cart produces exactly two,
//! and one of them is `05:$427E` reading $A000 in a loop that compares the
//! slot against `LD HL,$2083`. Eight bytes at 0:$2083 are `01 23 45 67 89 AB
//! CD EF`, which is a magic rather than data, so whatever *writes* a record
//! must stamp the same magic -- and the ROM contains exactly two references to
//! $2083, `21 83 20`, one of which is that comparison. The other is 1:$7AE4,
//! inside the routine below.
//!
//! `zig build disasm -- 1 0x7AD8 0x7B90 0x7ADF` is the whole of it: enable
//! cartridge RAM, copy the eight-byte magic to `$A000 + slot * 64`, then store
//! thirty-eight bytes with `LD (HL+),A` from a fixed list of sources. The list
//! *is* the record layout, and it is the game's own answer to "what is the
//! loadout" -- not a label list, and not a guess about which variables matter.
//!
//! ## What it independently confirms
//!
//! `01-requirements.md` names `metroidCountReal` at `$D089` and
//! `metroidCountDisplayed` at `$D09A`, both from M2RoS's labelling. Both are in
//! this routine, adjacent to each other at the end of the record, which is the
//! ROM agreeing with the labels rather than us transcribing them.
//!
//! ## How the rest were named, and which were not
//!
//! The routine says which addresses matter. It cannot say what any of them is.
//! `tas.Options.profile_record` answers that by watching all thirty-eight over
//! a replay of a published run and reporting, per field, its value at the
//! moment the game sets up a new file and how it moved afterwards. Metroid II
//! starts Samus with 99 energy and 30 missiles, and those two numbers land on
//! exactly one field each:
//!
//!     $D051  $99 at file start, falls, refills to $99, and is $00 on the
//!            frame the replay dies -> energy
//!     $D053  $30 at file start, falls to $17 over the run -> missiles carried
//!     $D081  $30 at file start and never moves again -> missile capacity
//!
//! **Equipment and beam are deliberately unnamed.** The plan asked for them and
//! the evidence does not reach them: every record field that is zero when the
//! file is set up is *still* zero, or a two-state flag, at the frame the replay
//! diverges. Both published runs desync before they collect anything that would
//! set an equipment bit -- 20 590 frames of the 100% run and 40 240 of the
//! any%. Naming them wants a replay that stays faithful for longer, or an item
//! pickup driven directly through the room harness; guessing between $D045,
//! $D055, $D050, $D052, $D054, $D082, $D092, $D098 and $D099 on the strength of
//! a plausible-looking bit pattern is exactly what `01-requirements.md` says not
//! to do.
//!
//! What the neighbours of a named field are is also left open on purpose. The
//! record stores $D050, $D051, $D052 consecutively and $D053 with $D054, which
//! looks like two- and three-byte quantities with the high digits at zero for
//! the whole early game -- looks like, which is not the same as is.

const std = @import("std");
const disasm = @import("gb/disasm.zig");
const offsets = @import("offsets.zig");

/// The slot is 64 bytes and there are three of them, from `05:$42AB`:
/// `LD A,($D0A3) / SLA A / SLA A / SWAP A / LD L,A / LD H,$A0` computes
/// `$A000 + slot * 64`, and the file counter sits at $A0C0, immediately after
/// the third.
pub const slot_size: u16 = 0x40;
pub const slot_base: u16 = 0xA000;
pub const slots: u8 = 3;
/// Which slot is in use, and the byte 05:$4290 writes to $A0C0.
pub const slot_index_addr: u16 = 0xD0A3;
pub const file_counter_addr: u16 = 0xA0C0;

/// The eight-byte "this slot holds a game" magic at 0:$2083.
pub const magic_addr: u16 = 0x2083;
pub const magic_len: u8 = 8;
pub const magic = [magic_len]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };

/// The routine that writes a record, and the window it lives in.
pub const writer_bank: u8 = 1;
pub const writer_addr: u16 = 0x7ADF;
pub const writer_end: u16 = 0x7B70;

/// One byte of the record: where it goes, and where it comes from.
pub const Field = struct {
    /// Offset into the 64-byte slot. The magic occupies 0-7.
    offset: u8,
    /// The address the writer reads it from.
    src: u16,
    /// What it is. Empty where the run below has not named it -- an honest
    /// blank rather than a plausible label.
    name: []const u8 = "",
};

/// The record, in the order the routine stores it.
///
/// Re-derived from the ROM by the test at the bottom, which decodes the
/// routine and rebuilds this list rather than checking it against itself.
pub const fields = [_]Field{
    .{ .offset = 8, .src = 0xFFC0, .name = "samus_y_in_screen" },
    .{ .offset = 9, .src = 0xFFC1 },
    .{ .offset = 10, .src = 0xFFC2, .name = "samus_x_in_screen" },
    .{ .offset = 11, .src = 0xFFC3 },
    .{ .offset = 12, .src = 0xFFC8, .name = "pixel_y" },
    .{ .offset = 13, .src = 0xFFC9, .name = "screen_row" },
    .{ .offset = 14, .src = 0xFFCA, .name = "pixel_x" },
    .{ .offset = 15, .src = 0xFFCB, .name = "screen_col" },
    // Thirteen bytes copied as a block from $D808, which is the only part of
    // the record the routine does not name one address at a time. $D811 -- the
    // map bank `room.zig` uses -- is the tenth of them.
    .{ .offset = 16, .src = 0xD808 },
    .{ .offset = 17, .src = 0xD809 },
    .{ .offset = 18, .src = 0xD80A },
    .{ .offset = 19, .src = 0xD80B },
    .{ .offset = 20, .src = 0xD80C },
    .{ .offset = 21, .src = 0xD80D },
    .{ .offset = 22, .src = 0xD80E },
    .{ .offset = 23, .src = 0xD80F },
    .{ .offset = 24, .src = 0xD810 },
    .{ .offset = 25, .src = 0xD811, .name = "map_bank" },
    .{ .offset = 26, .src = 0xD812 },
    .{ .offset = 27, .src = 0xD813 },
    .{ .offset = 28, .src = 0xD814 },
    .{ .offset = 29, .src = 0xD045 },
    .{ .offset = 30, .src = 0xD055 },
    .{ .offset = 31, .src = 0xD050 },
    .{ .offset = 32, .src = 0xD051, .name = "energy" },
    .{ .offset = 33, .src = 0xD052 },
    .{ .offset = 34, .src = 0xD081, .name = "missile_capacity" },
    .{ .offset = 35, .src = 0xD082 },
    .{ .offset = 36, .src = 0xD053, .name = "missiles" },
    .{ .offset = 37, .src = 0xD054 },
    .{ .offset = 38, .src = 0xD02B },
    .{ .offset = 39, .src = 0xD077 },
    .{ .offset = 40, .src = 0xD078 },
    .{ .offset = 41, .src = 0xD089, .name = "metroid_count_real" },
    .{ .offset = 42, .src = 0xD092 },
    .{ .offset = 43, .src = 0xD098 },
    .{ .offset = 44, .src = 0xD099 },
    .{ .offset = 45, .src = 0xD09A, .name = "metroid_count_displayed" },
};

pub const record_len: u8 = fields[fields.len - 1].offset + 1;

/// Decode the writer out of the ROM and rebuild `fields` from its stores.
///
/// The routine is a straight line of `LDH A,(n)` / `LD A,(nn)` / `LD (HL+),A`
/// plus one `LD DE,nn` block copy, so following it is a matter of remembering
/// the last address loaded and emitting one field per store. That is enough to
/// rebuild the layout without any of it being written down twice.
pub fn derive(allocator: std.mem.Allocator, rom: []const u8) ![]Field {
    var out: std.ArrayList(Field) = .empty;
    errdefer out.deinit(allocator);

    const base: usize = @as(usize, writer_bank) * 0x4000 - 0x4000;
    var pc: u16 = writer_addr;
    // The source of the byte currently in A, the block copy's pointer, and the
    // record offset the next store lands on.
    var src: ?u16 = null;
    var de: u16 = 0;
    var count: u8 = 0;
    var offset: u8 = magic_len;

    while (pc <= writer_end) {
        const i = base + pc;
        const op = rom[i];
        switch (op) {
            // LDH A,(n)
            0xF0 => {
                src = 0xFF00 | @as(u16, rom[i + 1]);
                pc += 2;
            },
            // LD A,(nn)
            0xFA => {
                src = std.mem.readInt(u16, rom[i + 1 ..][0..2], .little);
                pc += 3;
            },
            // LD DE,nn -- the block copy's source pointer.
            0x11 => {
                de = std.mem.readInt(u16, rom[i + 1 ..][0..2], .little);
                pc += 3;
            },
            // LD B,n -- a loop count. Either the magic copy's or the block's.
            0x06 => {
                count = rom[i + 1];
                pc += 2;
            },
            // The block copy, matched as a whole rather than walked: the
            // decoder here is straight-line, and a loop it walks once would
            // contribute one field where the routine contributes `count`.
            // `LD A,(DE) / INC DE / LD (HL+),A / DEC B / JR NZ,-6`.
            0x1A => {
                const shape = [_]u8{ 0x1A, 0x13, 0x22, 0x05, 0x20, 0xFA };
                if (!std.mem.eql(u8, rom[i..][0..shape.len], &shape)) return error.UnexpectedBlockCopy;
                for (0..count) |k| {
                    try out.append(allocator, .{ .offset = offset, .src = de +% @as(u16, @intCast(k)) });
                    offset += 1;
                }
                de +%= count;
                src = null;
                pc += shape.len;
            },
            // LD (HL+),A and LD (HL),A: one field each.
            0x22, 0x77 => {
                if (src) |v| {
                    try out.append(allocator, .{ .offset = offset, .src = v });
                    offset += 1;
                    src = null;
                }
                pc += 1;
            },
            // Everything else in the routine is the cartridge-RAM enable and
            // the magic copy, neither of which stores a record field.
            0x3E, 0xE0, 0xC6, 0x16, 0x26, 0xCB, 0x20 => pc += 2,
            0xEA, 0x21, 0xC3, 0xCD => pc += 3,
            else => pc += 1,
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- The record a new game starts from ------------------------------------
//
// `createNewSave` (01:4E1C) copies $26 bytes of ROM into `saveBuffer` and sets
// game mode $02, which is the only difference between starting a new game and
// loading one: `gameMode_LoadA` reads the same buffer either way. So this
// block is the game's own answer to "where does the game begin", and it is the
// answer the port's cold boot needs -- not a cell some search of ours picked,
// and not a middle-of-the-screen position the engine computed for itself.
//
// **It is the same 38 bytes `fields` describes**, in `saveBuffer` order: the
// SRAM writer stores $D808-$D814 as one block at record offsets 16-28, and
// those are bytes 8-20 here, at the same distance from the record's start. The
// two are one layout with two sources.
//
// Which of the field names below are evidence and which are transcription:
//
//   * `samus_y`, `samus_x`, `cam_y`, `cam_x` and `level_bank` are **measured**.
//     Frames 6 and 8 of the any% trace read $07D4,$0648 and $07C0,$0640 in map
//     bank $0F, which is this record arriving in the live variables one game
//     mode at a time. Nothing else in the record could produce those numbers.
//   * `tiletable_src` is **measured**: $5280 is `metatiles_surface`, and the
//     landing site is the surface.
//   * `collision_src` is measured the same way and is what found the defect in
//     `docs/bug_tracker.md` dated 2026-09-08: it reads $4580, which
//     `offsets.zig` had labelled `collision_lavaCaves`.
//   * `metroid_count_real` is **measured**: $47 is `$D089` at trace frame 6.
//   * `facing` is corroborated: $01 is `facing.right`, and the trace's first
//     movement at frame 330 is rightward.
//   * The rest are transcribed from M2RoS's `saveBuf_*` labels in `wram.asm`.
//     They are carried because the record is a fixed layout and skipping a
//     field would move every field after it, not because anything here has
//     confirmed what they mean.
pub const buffer_base: u16 = 0xD800;

/// The record's length, derived rather than written down: it is `fields`
/// without the eight magic bytes the SRAM slot puts in front of it.
pub const initial_len: usize = record_len - magic_len;

pub const Initial = struct {
    samus_y: u16,
    samus_x: u16,
    cam_y: u16,
    cam_x: u16,
    enemy_gfx_src: u16,
    bg_gfx_bank: u8,
    bg_gfx_src: u16,
    tiletable_src: u16,
    collision_src: u16,
    level_bank: u8,
    samus_solidity: u8,
    enemy_solidity: u8,
    beam_solidity: u8,
    items: u8,
    beam: u8,
    energy_tanks: u8,
    health: u16,
    max_missiles: u16,
    missiles: u16,
    facing: u8,
    acid_damage: u8,
    spike_damage: u8,
    metroid_count_real: u8,
    room_song: u8,
    minutes: u8,
    hours: u8,
    metroid_count_displayed: u8,

    /// The grid cell the record starts in: the screen halves of the two
    /// positions, packed the way a `WARP` operand packs them and the way
    /// `room.zig` reads them. $76 for this ROM, which is the trace's `$F:$76`.
    pub fn cell(self: Initial) u8 {
        return @intCast(((self.samus_y >> 8) << 4) | (self.samus_x >> 8));
    }
};

pub fn parseInitial(bytes: []const u8) ?Initial {
    if (bytes.len != initial_len) return null;
    const w = struct {
        fn at(b: []const u8, i: usize) u16 {
            return std.mem.readInt(u16, b[i..][0..2], .little);
        }
    };
    return .{
        .samus_y = w.at(bytes, 0),
        .samus_x = w.at(bytes, 2),
        .cam_y = w.at(bytes, 4),
        .cam_x = w.at(bytes, 6),
        .enemy_gfx_src = w.at(bytes, 8),
        .bg_gfx_bank = bytes[10],
        .bg_gfx_src = w.at(bytes, 11),
        .tiletable_src = w.at(bytes, 13),
        .collision_src = w.at(bytes, 15),
        .level_bank = bytes[17],
        .samus_solidity = bytes[18],
        .enemy_solidity = bytes[19],
        .beam_solidity = bytes[20],
        .items = bytes[21],
        .beam = bytes[22],
        .energy_tanks = bytes[23],
        .health = w.at(bytes, 24),
        .max_missiles = w.at(bytes, 26),
        .missiles = w.at(bytes, 28),
        .facing = bytes[30],
        .acid_damage = bytes[31],
        .spike_damage = bytes[32],
        .metroid_count_real = bytes[33],
        .room_song = bytes[34],
        .minutes = bytes[35],
        .hours = bytes[36],
        .metroid_count_displayed = bytes[37],
    };
}

pub fn encodeInitial(v: Initial) [initial_len]u8 {
    var out: [initial_len]u8 = @splat(0);
    const w = struct {
        fn put(b: []u8, i: usize, x: u16) void {
            std.mem.writeInt(u16, b[i..][0..2], x, .little);
        }
    };
    w.put(&out, 0, v.samus_y);
    w.put(&out, 2, v.samus_x);
    w.put(&out, 4, v.cam_y);
    w.put(&out, 6, v.cam_x);
    w.put(&out, 8, v.enemy_gfx_src);
    out[10] = v.bg_gfx_bank;
    w.put(&out, 11, v.bg_gfx_src);
    w.put(&out, 13, v.tiletable_src);
    w.put(&out, 15, v.collision_src);
    out[17] = v.level_bank;
    out[18] = v.samus_solidity;
    out[19] = v.enemy_solidity;
    out[20] = v.beam_solidity;
    out[21] = v.items;
    out[22] = v.beam;
    out[23] = v.energy_tanks;
    w.put(&out, 24, v.health);
    w.put(&out, 26, v.max_missiles);
    w.put(&out, 28, v.missiles);
    out[30] = v.facing;
    out[31] = v.acid_damage;
    out[32] = v.spike_damage;
    out[33] = v.metroid_count_real;
    out[34] = v.room_song;
    out[35] = v.minutes;
    out[36] = v.hours;
    out[37] = v.metroid_count_displayed;
    return out;
}

/// The record as it sits in the cartridge, or null if the entry is not pinned.
pub fn initial(rom: []const u8) ?Initial {
    const e = offsets.find("initial_save") orelse return null;
    if (e.romEnd() > rom.len) return null;
    return parseInitial(rom[e.romOffset()..e.romEnd()]);
}

// ---- The appearance sequence's own numbers --------------------------------

/// The last thing a load does, at 00:$0D0C, and the only place the game
/// decides how it opens.
///
/// `loadGame_samusData` ends with four `LD A,n` / `LD (nn),A` pairs -- the
/// pose, the countdown's two halves, and a song request -- and that shape is
/// what makes it findable: twenty bytes in which only the four immediates vary,
/// and exactly one place in the cartridge matches. So the port takes the
/// appearance sequence's pose and its length from the ROM rather than
/// transcribing two numbers out of a listing, which is the same discipline
/// every address in `offsets.zig` is held to.
///
/// It is not an `offsets.zig` entry because it is not data. It is four
/// instructions, and what is wanted from them is their operands.
pub const appearance_addr: u16 = 0x0D0C;

/// Where each of the four immediates is stored, in the order the routine
/// stores them. `samusPose` at $D020 and `countdownTimer` at $D066/$D067 are
/// M2RoS labels; what pins them here is that the retail bytes at
/// `appearance_addr` name exactly these three addresses in exactly this order,
/// and no other twenty bytes in the cartridge do.
const appearance_stores = [4]u16{ 0xD020, 0xD066, 0xD067, 0xCEDC };

pub const Appearance = struct {
    /// $13. The pose Samus stands in facing the camera.
    pose: u8,
    /// $0140 -- 320 frames, which is trace frames 6 to 325 of the any% run.
    countdown: u16,
    /// $12, the fanfare the sequence asks for, and `InitState` does ask for it
    /// (metroid2-audio Step 16a). Not written to `!Song`: that is
    /// `currentRoomSong`, which the room asks for once this sequence ends.
    song: u8,
};

pub fn appearance(rom: []const u8) ?Appearance {
    // `LD A,n` is $3E and `LD (nn),A` is $EA, so a pair is `3E ii EA lo hi`
    // with `ii` the operand wanted and `lo hi` a store this routine is
    // identified by. Bank 0 only: it is fixed, so the address is the offset.
    var found: ?Appearance = null;
    var at: usize = 0;
    const span = 5 * appearance_stores.len;
    while (at + span <= 0x4000) : (at += 1) {
        var imm: [appearance_stores.len]u8 = undefined;
        var ok = true;
        for (appearance_stores, 0..) |dst, i| {
            const p = rom[at + i * 5 ..][0..5];
            if (p[0] != 0x3E or p[2] != 0xEA) ok = false;
            if (!ok) break;
            if (std.mem.readInt(u16, p[3..5], .little) != dst) ok = false;
            if (!ok) break;
            imm[i] = p[1];
        }
        if (!ok) continue;
        // A second match would mean the signature does not identify the
        // routine, and taking the first would be a guess.
        if (found != null) return null;
        if (at != appearance_addr) return null;
        found = .{
            .pose = imm[0],
            .countdown = (@as(u16, imm[2]) << 8) | imm[1],
            .song = imm[3],
        };
    }
    return found;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the record layout is what the ROM's own writer stores" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // The magic, first: if this moved, the routine below is not the one.
    try testing.expectEqualSlices(u8, &magic, rom[magic_addr..][0..magic_len]);

    const got = try derive(a, rom);
    defer a.free(got);

    try testing.expectEqual(fields.len, got.len);
    for (fields, got) |want, have| {
        try testing.expectEqual(want.offset, have.offset);
        try testing.expectEqual(want.src, have.src);
    }
    // And it fits the slot it is written into, with room to spare.
    try testing.expect(record_len <= slot_size);
}

test "the routine that writes the record is the only other place the magic is named" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // `LD HL,$2083`. Two hits: the file-select comparison at 05:$426D that
    // found this, and the writer's own stamp at 01:$7AE4. A third would mean
    // there is another save path this file does not know about.
    const needle = [_]u8{ 0x21, @truncate(magic_addr), @truncate(magic_addr >> 8) };
    var hits: usize = 0;
    var found_writer = false;
    var i: usize = 0;
    while (i + needle.len <= rom.len) : (i += 1) {
        if (!std.mem.eql(u8, rom[i..][0..needle.len], &needle)) continue;
        hits += 1;
        const bank = i / 0x4000;
        const addr = i % 0x4000 + (if (bank == 0) @as(usize, 0) else 0x4000);
        if (bank == writer_bank and addr == 0x7AE4) found_writer = true;
    }
    try testing.expectEqual(@as(usize, 2), hits);
    try testing.expect(found_writer);
}

test "the disassembler agrees the writer is a routine that returns" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Decoded from its entry rather than swept: a linear sweep of this window
    // would decode the magic-copy loop's operands as instructions, which is
    // the failure mode `01-requirements.md` cites for a static-only tool.
    const start: u16 = 0x7AD8;
    const end: u16 = 0x7B90;
    const file_base = @as(usize, writer_bank) * 0x4000 + (start - 0x4000);
    var listing = try disasm.trace(arena, rom[file_base..][0 .. end - start], start, &.{writer_addr});
    defer listing.deinit(arena);

    // Every byte from the entry to the final store is proven code, which is
    // what says the window really is one routine and not a routine plus data
    // that happens to decode.
    var covered: usize = 0;
    for (listing.covered, 0..) |c, i| {
        const addr = start + i;
        if (addr >= writer_addr and addr <= writer_end and c) covered += 1;
    }
    try testing.expectEqual(@as(usize, writer_end - writer_addr + 1), covered);
}

/// Slot 0 as the game wrote it in James's recording, on the one frame game mode
/// `$09` ran: 23 001, read back by `zig build gbtrace -- saves 0 40000`. The
/// trace's own columns on that frame are the other half of the test below.
pub const recorded_save = [_]u8{
    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0xAC, 0x00, 0x6E, 0x04, 0xC0, 0x00, 0x8F, 0x04,
    0x20, 0x59, 0x07, 0x00, 0x58, 0x80, 0x50, 0x80, 0x44, 0x0F, 0x63, 0x5D, 0x63, 0x00, 0x00, 0x00,
    0x99, 0x00, 0x30, 0x00, 0x30, 0x00, 0x01, 0x02, 0x08, 0x46, 0x04, 0x06, 0x00, 0x38,
};

test "a record the game wrote decodes to what the trace shows on that frame" {
    // Not the layout checked against itself: these bytes are the cartridge's,
    // and the numbers below are the census's columns on frame 23 001 -- Samus
    // at pixel $AC of screen row 0 and pixel $6E of column 4, map bank $0F,
    // 99 energy, one Alpha down ($46) and the display at $38.
    try testing.expectEqual(@as(usize, record_len), recorded_save.len);
    try testing.expectEqualSlices(u8, &magic, recorded_save[0..magic_len]);
    const r = parseInitial(recorded_save[magic_len..]) orelse return error.BadRecord;
    try testing.expectEqual(@as(u16, 0x00AC), r.samus_y);
    try testing.expectEqual(@as(u16, 0x046E), r.samus_x);
    try testing.expectEqual(@as(u8, 0x04), r.cell());
    try testing.expectEqual(@as(u8, 0x0F), r.level_bank);
    try testing.expectEqual(@as(u16, 0x0099), r.health);
    try testing.expectEqual(@as(u8, 0x46), r.metroid_count_real);
    try testing.expectEqual(@as(u8, 0x38), r.metroid_count_displayed);
    // And `fields` names the same bytes `parseInitial` does.
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "energy")) try testing.expectEqual(@as(u8, 0x99), recorded_save[f.offset]);
        if (std.mem.eql(u8, f.name, "map_bank")) try testing.expectEqual(@as(u8, 0x0F), recorded_save[f.offset]);
        if (std.mem.eql(u8, f.name, "metroid_count_real")) try testing.expectEqual(@as(u8, 0x46), recorded_save[f.offset]);
    }
}

test "the appearance sequence's pose and length come out of the ROM" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const app = appearance(rom) orelse return error.NoAppearanceSequence;
    // $13 is `pose_faceScreen` and $0140 is 320 frames, which is what
    // `docs/slice.md` measured off the any% trace: the pose holds from frame 6
    // to frame 325 and control arrives on 326.
    try testing.expectEqual(@as(u8, 0x13), app.pose);
    try testing.expectEqual(@as(u16, 320), app.countdown);
    try testing.expectEqual(@as(u8, 0x12), app.song);

    // And the signature really does identify one routine. Perturbing any of
    // the three store addresses must find nothing rather than something else,
    // which is what says the twenty bytes are the load's ending and not a
    // shape the cartridge repeats.
    const perturbed = try a.dupe(u8, rom);
    defer a.free(perturbed);
    perturbed[appearance_addr + 3] +%= 1;
    try testing.expect(appearance(perturbed) == null);
}
