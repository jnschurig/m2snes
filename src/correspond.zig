//! The address correspondence map: each Game Boy variable the oracle traces,
//! paired with where the same thing lives on our machine.
//!
//! A frame-for-frame comparator needs to read "Samus's position" out of two
//! machines that agree about nothing else -- different CPUs, different memory
//! maps, different code. This is the table that lets it, and the plan asks for
//! one property above all: it must be **generated against the engine's symbol
//! file so it cannot silently drift**. So no SNES address is written down here.
//! Each pair names a label, `engine.sym` says where that label is, and a
//! missing label is an error rather than a zero.
//!
//! `engine/main.asm` exports the direct-page variables as `Var*` labels for
//! exactly this. They were assembler defines, which leave no trace in a symbol
//! file; the assignments are three lines of nothing that make the layout
//! readable from outside.
//!
//! ## The three shapes a correspondence takes
//!
//! Almost nothing is a plain address-for-address pair, and pretending otherwise
//! is how a comparator ends up reporting a divergence that is really a units
//! mismatch:
//!
//!   - **A position is two Game Boy bytes and one of ours.** The original keeps
//!     the screen number and the pixel within it in separate HRAM bytes; the
//!     engine keeps `screen << 8 | pixel` in one 16-bit direct-page word.
//!     `snes_screen.samusAt` is where that packing is stated, and the original's
//!     own camera arithmetic at 00:$294F is why it is the right one.
//!   - **A map is a bank there and an index here.** The Game Boy maps banks
//!     $9-$F; the converter numbers the same maps 0-6.
//!   - **A screen is a row and a column there and a cell byte here**, and the
//!     cell is `row * 16 + col`.

const std = @import("std");
const inject = @import("snes_inject.zig");
const snes_screen = @import("snes_screen.zig");
const room = @import("room.zig");
const tas = @import("tas.zig");
const locate = @import("locate.zig");
const testrom = @import("testrom");
const ledger = @import("ledger.zig");

pub const Error = error{ MissingSymbol, OutOfMemory };

pub const Transform = enum {
    /// One byte there, one byte here, same value.
    identity,
    /// Two Game Boy bytes -- `gb` the pixel, `gb_hi` the screen -- against one
    /// 16-bit word here.
    screen_pixel_pair,
    /// Map bank $9-$F there, converted map index 0-6 here.
    map_bank_to_index,
    /// Screen row in `gb_hi` and column in `gb`, against one cell byte here.
    row_col_to_cell,
};

pub const Pair = struct {
    name: []const u8,
    /// The low half: the pixel, the column, or the whole byte.
    gb: u16,
    /// The high half, where the Game Boy keeps one.
    gb_hi: ?u16 = null,
    /// The label in `engine.sym`. Never an address.
    snes: []const u8,
    /// Bytes on our side.
    width: u8,
    transform: Transform,
    /// The routine in `locate.routines` that must be observed writing `gb`
    /// over a published tool-assisted run, or null where no single routine
    /// owns the address.
    ///
    /// **This is the obligation the Game Boy side of the map did not have.**
    /// The SNES side cannot be wrong: it names an `engine.sym` label and a
    /// missing label is an error. The Game Boy side was hand-typed hex with a
    /// note explaining itself, and a note is not a check -- `samus_y` carried a
    /// perfectly reasonable one while pointing at an address that is not Samus.
    /// Naming the owner turns the claim into something a run can refute.
    owner: ?[]const u8 = null,
    /// The owner of `gb_hi`, where the two halves are owned by different
    /// routines. Defaults to `owner`.
    ///
    /// `screen` is the case that forced this: the cell byte is a row and a
    /// column, and the two axes are moved by different code. Letting one name
    /// stand for both would have meant either a false claim or no claim, and
    /// the whole point of this field is that it is neither.
    owner_hi: ?[]const u8 = null,
    /// How we know the Game Boy address.
    note: []const u8,
};

pub const pairs = [_]Pair{
    .{
        .name = "samus_x",
        .gb = room.samus_pixel_x_addr,
        .gb_hi = room.samus_screen_x_addr,
        .snes = "VarSamusX",
        .width = 2,
        .transform = .screen_pixel_pair,
        .owner = "samus_walkRight",
        .note = "$FFC2 over $FFC3. **Corrected 2026-08-31; it used to name $FFCA/$FFCB.** The old note argued from the `WARP` handler, which writes both quads at a transition and neither afterwards -- an inference from initialisation that a single frame of play refutes. `locate.zig` settles it by replay: 4740 writes over 3600 frames, every one from the movement routines at 0:$1C2F-$1D46, against 553 to $FFCA from the scroll-edge code.",
    },
    .{
        .name = "samus_y",
        .gb = room.samus_pixel_y_addr,
        .gb_hi = room.samus_screen_y_addr,
        .snes = "VarSamusY",
        .width = 2,
        .transform = .screen_pixel_pair,
        .owner = "samus_moveVertical",
        .note = "$FFC0 over $FFC1, and the axis the wrong answer was most expensive on: $FFC8 does not move at all during ordinary play, so the Y rung of the comparator was comparing a constant against a constant for the whole segment and could not fail. 409 writes from `samus_moveVertical` at 0:$1D5A and 0:$1D9C.",
    },
    .{
        .name = "camera_x",
        .gb = tas.camera_pixel_x_addr,
        .gb_hi = tas.camera_col_addr,
        .snes = "VarCamX",
        .width = 2,
        .transform = .screen_pixel_pair,
        .owner = "camera_update",
        .note = "$FFCA over $FFCB. **Corrected 2026-08-31**: this was $FFCE/$FFCF, which `screens.zig` had pinned by watching what the frame renderer reads. The renderer does read them -- they are the camera rounded down to a screen (00:$0675), so they step in metatile units and stand still in between, and the segment's camera rung was grading a staircase against a slope. The camera is what 00:$08FE adds the walk speed to.",
    },
    .{
        .name = "camera_y",
        .gb = tas.camera_pixel_y_addr,
        .gb_hi = tas.camera_row_addr,
        .snes = "VarCamY",
        .width = 2,
        .transform = .screen_pixel_pair,
        .owner = "camera_update",
        .note = "$FFC8 over $FFC9, the other axis of the same routine.",
    },
    .{
        .name = "pose",
        .gb = ledger.pose_addr,
        .snes = "VarPose",
        .width = 1,
        .transform = .identity,
        .note = "$D020 is what `samus_handlePose` at 00:$0D21 loads before its `RST $28`, which is the whole pose machine's dispatch.",
    },
    .{
        .name = "map",
        .gb = room.map_bank_addr,
        .snes = "VarMapIndex",
        .width = 1,
        .transform = .map_bank_to_index,
        .note = "$D811 is the copy the warp handler makes at $2901. Not $D04E, which is a shadow of whatever bank is mapped -- see `room.map_bank_addr`.",
    },
    .{
        .name = "screen",
        .gb = room.samus_screen_x_addr,
        .gb_hi = room.samus_screen_y_addr,
        .snes = "VarCell",
        .width = 1,
        .transform = .row_col_to_cell,
        .owner = "samus_walkRight",
        .owner_hi = "samus_moveVertical",
        .note = "`probe.runDoors` proved the grid is 16x16 indexed `row * 16 + col` by watching which screen-pointer entry the engine read. The row and column come from **Samus's own quad**, $FFC3 over $FFC1, corrected 2026-08-31 with the position pairs: the cell the comparator means is the one she is standing in, and the screen nibbles of the other quad follow the scroll instead. `samus_walkRight` is named as the owner because the nibble is the carry out of her X, written by the same instruction.",
    },
};

/// A pair with its SNES address filled in from the symbol file.
pub const Resolved = struct {
    pair: Pair,
    /// The full SNES address. Direct-page variables come back as bank 0 with
    /// the address in the low word.
    addr: u32,

    /// The direct-page offset, for a variable that is one.
    pub fn dp(self: Resolved) ?u8 {
        if (self.addr > 0xFF) return null;
        return @truncate(self.addr);
    }
};

/// Resolve every pair, or say which label is missing.
///
/// The error is the point: if somebody deletes `VarSamusX` from
/// `engine/main.asm`, this fails loudly instead of the comparator reading
/// address zero and reporting that the two machines agree perfectly.
pub fn resolve(allocator: std.mem.Allocator, missing: *[]const u8) Error![]Resolved {
    const out = try allocator.alloc(Resolved, pairs.len);
    errdefer allocator.free(out);
    for (pairs, 0..) |p, i| {
        const addr = inject.symbol(p.snes) orelse {
            missing.* = p.snes;
            return Error.MissingSymbol;
        };
        out[i] = .{ .pair = p, .addr = addr };
    }
    return out;
}

/// Read one pair's value out of a Game Boy machine, in our units.
///
/// "In our units" is what makes this the correspondence map rather than a list
/// of addresses: the caller gets a number it can compare against the SNES side
/// directly, with the packing and the bank-to-index arithmetic already applied.
pub fn readGb(p: Pair, read: *const fn (ctx: *anyopaque, addr: u16) u8, ctx: *anyopaque) u16 {
    const lo = read(ctx, p.gb);
    return switch (p.transform) {
        .identity => lo,
        .screen_pixel_pair => (@as(u16, read(ctx, p.gb_hi.?)) << 8) | lo,
        .map_bank_to_index => lo -% room.map_bank_first,
        .row_col_to_cell => (@as(u16, read(ctx, p.gb_hi.?)) << 4) | (lo & 0x0F),
    };
}

/// The map as Lua, for the generated oracle script: one `local` per pair
/// holding the direct-page address the SNES side reads.
pub fn luaConstants(allocator: std.mem.Allocator, resolved: []const Resolved) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "-- Generated from engine.sym by src/correspond.zig. Do not edit.\n", .{});
    for (resolved) |r| {
        try out.print(allocator, "local AT_{s} = 0x{X:0>4}  -- {s}, {d} byte(s)\n", .{
            r.pair.name, r.addr & 0xFFFF, r.pair.snes, r.pair.width,
        });
    }
    return out.toOwnedSlice(allocator);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "every pair names a label the engine actually exports" {
    var missing: []const u8 = "";
    const got = resolve(testing.allocator, &missing) catch |e| {
        std.debug.print("engine.sym has no label {s}\n", .{missing});
        return e;
    };
    defer testing.allocator.free(got);

    try testing.expectEqual(pairs.len, got.len);
    for (got) |r| {
        // Every one of these is a direct-page variable, so it lives in bank 0
        // below $0100. A label that resolved into ROM would mean the name had
        // been satisfied by a routine rather than by the variable.
        try testing.expect(r.addr < 0x100);
        try testing.expect(r.dp() != null);
    }

    // And no two pairs point at the same place on either side, which would
    // mean the comparator was checking one thing twice and another not at all.
    for (got, 0..) |a, i| {
        for (got[i + 1 ..]) |b| {
            try testing.expect(a.addr != b.addr);
            try testing.expect(!(a.pair.gb == b.pair.gb and a.pair.transform == b.pair.transform));
        }
    }
}

test "the Game Boy's split halves pack into the number the SNES side holds" {
    // A fake machine, so this tests the arithmetic rather than the emulator.
    const Fake = struct {
        mem: std.AutoHashMap(u16, u8),
        fn read(ctx: *anyopaque, addr: u16) u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.mem.get(addr) orelse 0;
        }
    };
    var f: Fake = .{ .mem = std.AutoHashMap(u16, u8).init(testing.allocator) };
    defer f.mem.deinit();

    // Cell $3A: row 3, column $A. Pixel $80 across, $40 down.
    try f.mem.put(room.samus_screen_y_addr, 3);
    try f.mem.put(room.samus_screen_x_addr, 0xA);
    try f.mem.put(room.samus_pixel_x_addr, 0x80);
    try f.mem.put(room.samus_pixel_y_addr, 0x40);
    try f.mem.put(room.map_bank_addr, 0xB);

    const want = snes_screen.samusAt(0x3A, 0x80, 0x40);
    for (pairs) |p| {
        const v = readGb(p, Fake.read, &f);
        if (std.mem.eql(u8, p.name, "samus_x")) try testing.expectEqual(want.x, v);
        if (std.mem.eql(u8, p.name, "samus_y")) try testing.expectEqual(want.y, v);
        // Bank $B is the third map the converter numbers, 0-based.
        if (std.mem.eql(u8, p.name, "map")) try testing.expectEqual(@as(u16, 2), v);
        if (std.mem.eql(u8, p.name, "screen")) try testing.expectEqual(@as(u16, 0x3A), v);
    }
}

test "the generated Lua carries one address per pair and no hand-written ones" {
    const a = testing.allocator;
    var missing: []const u8 = "";
    const got = try resolve(a, &missing);
    defer a.free(got);

    const lua = try luaConstants(a, got);
    defer a.free(lua);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, lua, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "local AT_")) lines += 1;
    }
    try testing.expectEqual(pairs.len, lines);
    for (pairs) |p| {
        const needle = try std.fmt.allocPrint(a, "local AT_{s} = ", .{p.name});
        defer a.free(needle);
        try testing.expect(std.mem.indexOf(u8, lua, needle) != null);
    }
}

test "every pair's Game Boy address is written by the routine that claims to own it" {
    // **The check this table was missing.** No SNES address can be wrong here:
    // it names an `engine.sym` label and a missing label is an error. Until
    // this test the Game Boy side had nothing but a prose note, and `samus_y`
    // carried a perfectly convincing one while naming $FFC8 -- an address the
    // game does not write during play at all, which is why 320 frames of
    // comparison could not fail.
    //
    // The ground truth is a published tool-assisted run: forty thousand frames
    // of somebody else playing the real game, which is the one reference in
    // this project that cannot have been shaped to agree with the port.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        tas.any_percent,
        a,
        .limited(64 << 20),
    ) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try tas.parse(bytes);

    var obs = try locate.observe(a, rom, movie, .{});
    defer obs.deinit();

    for (pairs) |p| {
        const owner = p.owner orelse continue;
        const i = locate.Observation.indexOf(owner) orelse {
            std.debug.print("pair '{s}' names an owner '{s}' that locate.routines does not have\n", .{ p.name, owner });
            return error.UnknownOwner;
        };
        // A routine that never ran proves nothing either way, and reporting
        // that as a pass would put the original mistake back in a new place.
        if (!obs.ran(i)) {
            std.debug.print("owner '{s}' never executed; the replay is too short to judge '{s}'\n", .{ owner, p.name });
            return error.OwnerNeverRan;
        }
        if (!obs.wroteTo(i, p.gb)) {
            std.debug.print("'{s}': {s} never wrote ${X:0>4}\n", .{ p.name, owner, p.gb });
            return error.NotWrittenByOwner;
        }
        if (p.gb_hi) |hi| {
            const hi_owner = p.owner_hi orelse owner;
            const j = locate.Observation.indexOf(hi_owner) orelse return error.UnknownOwner;
            if (!obs.ran(j)) return error.OwnerNeverRan;
            if (!obs.wroteTo(j, hi)) {
                std.debug.print("'{s}': {s} never wrote ${X:0>4}\n", .{ p.name, hi_owner, hi });
                return error.NotWrittenByOwner;
            }
        }
    }

    // And the check has teeth: the addresses the table used to name are the
    // ones a run refutes. Without this the test above would pass against a
    // predicate that is accidentally always true.
    const walk = locate.Observation.indexOf("samus_walkRight").?;
    const vert = locate.Observation.indexOf("samus_moveVertical").?;
    for ([_]u16{ room.pixel_x_addr, room.screen_col_addr }) |addr| {
        try testing.expect(!obs.wroteTo(walk, addr));
    }
    for ([_]u16{ room.pixel_y_addr, room.screen_row_addr }) |addr| {
        try testing.expect(!obs.wroteTo(vert, addr));
    }
}

// ---------------------------------------------------------------------------

const sprites = @import("sprites.zig");
const offsets = @import("offsets.zig");

test "the load searches every pointer the two pointer tables hold" {
    // `LoadSaveGraphics` finds a record's metatile and collision tables by
    // searching the pointer tables for the record's pointer, and reaches
    // `Fatal` when it runs off the end. `!META_PTRS_N` was 8 against a table
    // of ten until Step 22, so a save in a room on TILETABLE 8 (lava at Mid)
    // or 9 (`ruinsExt`) could not be loaded.
    const meta: usize = inject.symbol("ConstMetaPtrsN") orelse return error.MissingSymbol;
    const coll: usize = inject.symbol("ConstCollBlobs") orelse return error.MissingSymbol;
    try testing.expectEqual(offsets.find("metatile_pointers").?.size / 2, meta);
    try testing.expectEqual(offsets.find("collision_pointers").?.size / 2, coll);
}

test "the engine's knockback and ball sprite ids are the cartridge's" {
    // The same argument as the table above, applied to four numbers that were
    // not a table. `SamusSpriteId` draws poses $0F/$11 from two immediates and
    // poses $05/$06/$08/$10/$12 from two bases plus a 0-3 frame index, because
    // `drawSamus_knockback` indexes two bytes and `drawSamus_morph` indexes two
    // consecutive runs of four. Both readings are right, and until Step 11
    // pinned 01:$4C69 and 01:$4CB5 nothing in this repository could say so:
    // the four bytes were transcribed from a disassembly and graded by nobody.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    {
        const e = offsets.find("pose_sprites_knockback") orelse return error.Missing;
        const t = try sprites.parsePoseTable(a, rom[e.romOffset()..e.romEnd()]);
        defer a.free(t.ids);
        try testing.expectEqual(sprites.facing_pair, t.row);
        const l: u8 = @truncate(inject.symbol("ConstSprKnockL") orelse return error.MissingSymbol);
        const r: u8 = @truncate(inject.symbol("ConstSprKnockR") orelse return error.MissingSymbol);
        try testing.expectEqual(t.ids[0], l);
        try testing.expectEqual(t.ids[1], r);
    }

    {
        const e = offsets.find("pose_sprites_morph") orelse return error.Missing;
        const t = try sprites.parsePoseTable(a, rom[e.romOffset()..e.romEnd()]);
        defer a.free(t.ids);
        try testing.expectEqual(@as(usize, 2), t.rows());
        const l: u8 = @truncate(inject.symbol("ConstSprBallL") orelse return error.MissingSymbol);
        const r: u8 = @truncate(inject.symbol("ConstSprBallR") orelse return error.MissingSymbol);
        try testing.expectEqual(t.at(0)[0], l);
        try testing.expectEqual(t.at(1)[0], r);
        // The bases-plus-index reading is only correct because each row counts
        // up by one. Asserting that is what makes the two immediates a
        // *derivation* of the table rather than a coincidence at entry zero.
        for (0..2) |row| {
            for (1..sprites.row_ids) |i| {
                try testing.expectEqual(t.at(row)[i - 1] + 1, t.at(row)[i]);
            }
        }
    }
}

test "every equipment mask is the bit that pickup arm sets in the cartridge" {
    // **The check `!Items` never had.** Six masks sat in `engine/main.asm`
    // transcribed from M2RoS's `itemBit_*` names, read by nine branches in the
    // pose machine, and graded by nothing at all - because `!Items` is zero for
    // the whole of Phase 0a, so every one of those branches took its
    // empty-handed path and a wrong mask could not show.
    //
    // The oracle is the cartridge: `handleItemPickup`'s fifteen arms are the
    // ROM stating which bit each item is, and `items.bitFor` reads it out of
    // the `SET n,A` opcode rather than out of a name.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const masks = [_]struct { sym: []const u8, item: items.Collected }{
        .{ .sym = "ConstItemBomb", .item = .bomb },
        .{ .sym = "ConstItemHiJump", .item = .high_jump },
        .{ .sym = "ConstItemScrew", .item = .screw_attack },
        .{ .sym = "ConstItemSpace", .item = .space_jump },
        .{ .sym = "ConstItemSpring", .item = .spring_ball },
        .{ .sym = "ConstItemSpider", .item = .spider_ball },
        .{ .sym = "ConstItemVaria", .item = .varia },
    };
    var bad: usize = 0;
    for (masks) |p| {
        const bit = (try items.bitFor(rom, p.item)) orelse return error.NoBit;
        const want: u8 = @as(u8, 1) << bit;
        const got: u8 = @truncate(inject.symbol(p.sym) orelse return error.MissingSymbol);
        if (got != want) {
            std.debug.print(
                "{s}: engine has ${X:0>2}, the cartridge's arm sets bit {d} (${X:0>2})\n",
                .{ p.sym, got, bit, want },
            );
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "every block constant is the operand of the opcode it was read out of" {
    // **The check the block mechanism would otherwise not have.** Sixteen
    // numbers went into `engine/main.asm`'s `!BLK_*` block in one turn, and
    // nothing on this cart fires at a block yet -- so a wrong counter would
    // show as an animation nobody is watching, and a wrong bit as a wall that
    // quietly refuses to break. That is exactly the shape of the equipment-mask
    // bug above: a constant that is never exercised is a constant that is never
    // graded.
    //
    // The oracle is the cartridge. `src/blocks.zig` reads each number out of
    // the `CP d8`, `LD A,d8`, `ADD A,d8` or `BIT n,A` that carries it, refusing
    // to return anything if the byte at the address is not that opcode.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstBlockShot", .want = try blocks.shotMask(rom), .from = "01:$5176 BIT n,A" },
        .{ .sym = "ConstBlockBomb", .want = try blocks.bombMask(rom), .from = "01:$5543 BIT n,A" },
        .{ .sym = "ConstBlockAcid", .want = try blocks.acidMask(rom), .from = "00:$1EC5 BIT n,A" },
        .{ .sym = "ConstBlkCrack1", .want = try blocks.compareAt(rom, blocks.counter_sites[0]), .from = "01:$56BC CP d8" },
        .{ .sym = "ConstBlkCrack2", .want = try blocks.compareAt(rom, blocks.counter_sites[1]), .from = "01:$56C1 CP d8" },
        .{ .sym = "ConstBlkEmptyAt", .want = try blocks.compareAt(rom, blocks.counter_sites[2]), .from = "01:$56C6 CP d8" },
        .{ .sym = "ConstBlkCrack3", .want = try blocks.compareAt(rom, blocks.counter_sites[3]), .from = "01:$56CA CP d8" },
        .{ .sym = "ConstBlkCrack4", .want = try blocks.compareAt(rom, blocks.counter_sites[4]), .from = "01:$56CF CP d8" },
        .{ .sym = "ConstBlkReform", .want = try blocks.compareAt(rom, blocks.counter_sites[5]), .from = "01:$56D3 CP d8" },
        .{ .sym = "ConstBlkEvictY", .want = try blocks.compareAt(rom, blocks.evict_sites[0]), .from = "01:$56A6 CP d8" },
        .{ .sym = "ConstBlkEvictX", .want = try blocks.compareAt(rom, blocks.evict_sites[1]), .from = "01:$56B5 CP d8" },
        .{ .sym = "ConstBlkTileGone", .want = try blocks.loadAt(rom, blocks.tile_gone_site), .from = "01:$5705 LD A,d8" },
        .{ .sym = "ConstBlkTileA", .want = try blocks.loadAt(rom, blocks.tile_crack_a_site), .from = "01:$575E LD A,d8" },
        .{ .sym = "ConstBlkTileB", .want = try blocks.loadAt(rom, blocks.tile_crack_b_site), .from = "01:$5785 LD A,d8" },
        .{ .sym = "ConstBlkSize", .want = try blocks.addAt(rom, blocks.stride_site), .from = "01:$5679 ADD A,d8" },
        .{ .sym = "ConstBlkRespawnIds", .want = try blocks.compareAt(rom, blocks.respawn_ids_site), .from = "01:$5168 CP d8" },
    };

    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print(
                "{s}: engine has ${X:0>2}, the cartridge's {s} says ${X:0>2}\n",
                .{ c.sym, got, c.from, c.want },
            );
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}


test "every projectile constant is the operand of the opcode it was read out of" {
    // The same argument the block constants' test makes, and it applies harder
    // here: twenty-six numbers went into `engine/main.asm`'s projectile block
    // in one turn, and the ones that decide *range* and *speed* are the kind of
    // wrong that looks like a design choice. A beam that stops four pixels
    // early is a beam, and no rung in this repository would call it anything
    // else -- so the cartridge is asked instead.
    //
    // Every site is an instruction, not an offset: `blocks.compareAt` and its
    // neighbours refuse to return anything when the byte at the address is not
    // the opcode named beside it, so a table that drifted would fail loudly
    // rather than read a plausible byte out of the middle of something else.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstBeamCooldown", .want = try blocks.compareAt(rom, 0x4E9C), .from = "01:$4E9C CP d8" },
        .{ .sym = "ConstShotBomb", .want = try blocks.compareAt(rom, 0x4EB2), .from = "01:$4EB2 CP d8" },
        .{ .sym = "ConstShotOriginBias", .want = try blocks.subAt(rom, 0x4EF1), .from = "01:$4EF1 SUB d8" },
        .{ .sym = "ConstPrSize", .want = try blocks.addAt(rom, 0x4FCE), .from = "01:$4FCE ADD A,d8" },
        .{ .sym = "ConstWpnWave", .want = try blocks.compareAt(rom, 0x503E), .from = "01:$503E CP d8" },
        .{ .sym = "ConstWpnSpazer", .want = try blocks.compareAt(rom, 0x5043), .from = "01:$5043 CP d8" },
        .{ .sym = "ConstWpnMissile", .want = try blocks.compareAt(rom, 0x5047), .from = "01:$5047 CP d8" },
        .{ .sym = "ConstSpazerSpread", .want = try blocks.compareAt(rom, 0x509C), .from = "01:$509C CP d8" },
        .{ .sym = "ConstSpazerSplit", .want = try blocks.subAt(rom, 0x50AB), .from = "01:$50AB SUB d8" },
        .{ .sym = "ConstWaveSpd", .want = try blocks.addAt(rom, 0x5100), .from = "01:$5100 ADD A,d8" },
        .{ .sym = "ConstBeamSpd", .want = try blocks.addAt(rom, 0x521E), .from = "01:$521E ADD A,d8" },
        .{ .sym = "ConstWpnPlasma", .want = try blocks.compareAt(rom, 0x5228), .from = "01:$5228 CP d8" },
        .{ .sym = "ConstPlasmaExtra", .want = try blocks.addAt(rom, 0x522E), .from = "01:$522E ADD A,d8" },
        .{ .sym = "ConstPrHitBias", .want = try blocks.addAt(rom, 0x528D), .from = "01:$528D ADD A,d8" },
        .{ .sym = "ConstWpnBombBeam", .want = try blocks.compareAt(rom, 0x52C8), .from = "01:$52C8 CP d8" },
        .{ .sym = "ConstSprBeamH", .want = try blocks.loadAt(rom, 0x534C), .from = "01:$534C LD A,d8" },
        .{ .sym = "ConstSprBeamV", .want = try blocks.loadAt(rom, 0x5355), .from = "01:$5355 LD A,d8" },
        .{ .sym = "ConstPrWinLeft", .want = try blocks.compareAt(rom, 0x535B), .from = "01:$535B CP d8" },
        .{ .sym = "ConstPrWinRight", .want = try blocks.compareAt(rom, 0x5361), .from = "01:$5361 CP d8" },
        .{ .sym = "ConstPrWinTop", .want = try blocks.compareAt(rom, 0x5367), .from = "01:$5367 CP d8" },
        .{ .sym = "ConstPrWinBot", .want = try blocks.compareAt(rom, 0x536D), .from = "01:$536D CP d8" },
        // And the five in bank 2, where the enemy takes the damage.
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x4257), .from = "02:$4257 CP d8" },
        .{ .sym = "ConstSprMetroidLo", .want = try blocks.compareIn(rom, 2, 0x42D0), .from = "02:$42D0 CP d8" },
        .{ .sym = "ConstSprMetroidHi", .want = try blocks.compareIn(rom, 2, 0x42D4), .from = "02:$42D4 CP d8" },
        .{ .sym = "ConstEnHpInvuln", .want = try blocks.compareIn(rom, 2, 0x4320), .from = "02:$4320 CP d8" },
        .{ .sym = "ConstEnStunHit", .want = try blocks.loadIn(rom, 2, 0x4333), .from = "02:$4333 LD A,d8" },
    };

    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print(
                "{s}: engine has ${X:0>2}, the cartridge's {s} says ${X:0>2}\n",
                .{ c.sym, got, c.from, c.want },
            );
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "every bomb constant is the operand of the opcode it was read out of" {
    // Step 12c's. Most of them appear at more than one site -- the fuse is
    // loaded by both ways of laying a bomb, the probe distance is added and
    // subtracted four times, and the enemy pad eight -- and **every site is a
    // row**, because a constant that agrees with one of its sites and not
    // another is a constant the engine is using for two different numbers.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstBombLive", .want = try blocks.loadAt(rom, 0x53C3), .from = "01:$53C3 LD A,d8" },
        .{ .sym = "ConstBombLive", .want = try blocks.loadAt(rom, 0x53F8), .from = "01:$53F8 LD A,d8" },
        .{ .sym = "ConstBombLive", .want = try blocks.compareAt(rom, 0x5449), .from = "01:$5449 CP d8" },
        .{ .sym = "ConstBombLive", .want = try blocks.compareAt(rom, 0x54B7), .from = "01:$54B7 CP d8" },
        .{ .sym = "ConstBombFuse", .want = try blocks.loadAt(rom, 0x53C6), .from = "01:$53C6 LD A,d8" },
        .{ .sym = "ConstBombFuse", .want = try blocks.loadAt(rom, 0x53FB), .from = "01:$53FB LD A,d8" },
        .{ .sym = "ConstBombBlast", .want = try blocks.loadAt(rom, 0x54C2), .from = "01:$54C2 LD A,d8" },
        .{ .sym = "ConstBombBlastN", .want = try blocks.loadAt(rom, 0x54C5), .from = "01:$54C5 LD A,d8" },
        .{ .sym = "ConstBombBlastN", .want = try blocks.compareAt(rom, 0x545E), .from = "01:$545E CP d8" },
        .{ .sym = "ConstBombCount", .want = try blocks.compareAt(rom, 0x5497), .from = "01:$5497 CP d8" },
        .{ .sym = "ConstBombCount", .want = try blocks.compareAt(rom, 0x54CF), .from = "01:$54CF CP d8" },
        .{ .sym = "ConstBombLayY", .want = try blocks.addAt(rom, 0x5400), .from = "01:$5400 ADD A,d8" },
        .{ .sym = "ConstBombLayX", .want = try blocks.addAt(rom, 0x5405), .from = "01:$5405 ADD A,d8" },
        .{ .sym = "ConstBombBeamOfs", .want = try blocks.addAt(rom, 0x53CB), .from = "01:$53CB ADD A,d8" },
        .{ .sym = "ConstBombBeamOfs", .want = try blocks.addAt(rom, 0x53D0), .from = "01:$53D0 ADD A,d8" },
        .{ .sym = "ConstSfxBombLaid", .want = try blocks.loadAt(rom, 0x53D3), .from = "01:$53D3 LD A,d8" },
        .{ .sym = "ConstSfxBombLaid", .want = try blocks.loadAt(rom, 0x5408), .from = "01:$5408 LD A,d8" },
        .{ .sym = "ConstBombWin", .want = try blocks.compareAt(rom, 0x543D), .from = "01:$543D CP d8" },
        .{ .sym = "ConstBombWin", .want = try blocks.compareAt(rom, 0x5443), .from = "01:$5443 CP d8" },
        .{ .sym = "ConstSprBomb", .want = try blocks.addAt(rom, 0x5454), .from = "01:$5454 ADD A,d8" },
        .{ .sym = "ConstSprBombExp", .want = try blocks.addAt(rom, 0x546D), .from = "01:$546D ADD A,d8" },
        .{ .sym = "ConstSprBombExp", .want = try blocks.addAt(rom, 0x5481), .from = "01:$5481 ADD A,d8" },
        .{ .sym = "ConstPoseEaten", .want = try blocks.compareAt(rom, 0x5465), .from = "01:$5465 CP d8" },
        .{ .sym = "ConstSfxBombBlast", .want = try blocks.loadAt(rom, 0x5477), .from = "01:$5477 LD A,d8" },
        .{ .sym = "ConstBombReachY", .want = try blocks.subAt(rom, 0x54E0), .from = "01:$54E0 SUB d8" },
        .{ .sym = "ConstBombReachY", .want = try blocks.addAt(rom, 0x54E8), .from = "01:$54E8 ADD A,d8" },
        .{ .sym = "ConstBombReachX", .want = try blocks.subAt(rom, 0x54F3), .from = "01:$54F3 SUB d8" },
        .{ .sym = "ConstBombReachX", .want = try blocks.addAt(rom, 0x54FB), .from = "01:$54FB ADD A,d8" },
        .{ .sym = "ConstBombArc", .want = try blocks.loadAt(rom, 0x5512), .from = "01:$5512 LD A,d8" },
        .{ .sym = "ConstBombProbe", .want = try blocks.subAt(rom, 0x5528), .from = "01:$5528 SUB d8" },
        .{ .sym = "ConstBombProbe", .want = try blocks.addAt(rom, 0x5570), .from = "01:$5570 ADD A,d8" },
        .{ .sym = "ConstBombProbe", .want = try blocks.addAt(rom, 0x5598), .from = "01:$5598 ADD A,d8" },
        .{ .sym = "ConstBombProbe", .want = try blocks.subAt(rom, 0x55BA), .from = "01:$55BA SUB d8" },
        .{ .sym = "ConstBlkRespawnIds", .want = try blocks.compareAt(rom, 0x5536), .from = "01:$5536 CP d8" },
        // And the enemy half, in bank 0.
        .{ .sym = "ConstBombEnPad", .want = try blocks.subIn(rom, 0, 0x3120), .from = "00:$3120 SUB d8" },
        .{ .sym = "ConstBombEnPad", .want = try blocks.addIn(rom, 0, 0x3126), .from = "00:$3126 ADD A,d8" },
        .{ .sym = "ConstBombEnPad", .want = try blocks.addIn(rom, 0, 0x312F), .from = "00:$312F ADD A,d8" },
        .{ .sym = "ConstBombEnPad", .want = try blocks.subIn(rom, 0, 0x3136), .from = "00:$3136 SUB d8" },
        .{ .sym = "ConstBombEnPad", .want = try blocks.subIn(rom, 0, 0x3145), .from = "00:$3145 SUB d8" },
        .{ .sym = "ConstBombEnPad", .want = try blocks.addIn(rom, 0, 0x314B), .from = "00:$314B ADD A,d8" },
        .{ .sym = "ConstBombEnPad", .want = try blocks.addIn(rom, 0, 0x3154), .from = "00:$3154 ADD A,d8" },
        .{ .sym = "ConstBombEnPad", .want = try blocks.subIn(rom, 0, 0x315B), .from = "00:$315B SUB d8" },
        .{ .sym = "ConstWpnBomb", .want = try blocks.loadIn(rom, 0, 0x3179), .from = "00:$3179 LD A,d8" },
    };

    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print(
                "{s}: engine has ${X:0>2}, the cartridge's {s} says ${X:0>2}\n",
                .{ c.sym, got, c.from, c.want },
            );
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // `samus_bombPoseTable` is a physics blob, graded against the ROM by
    // `snes_convert`; what is asserted here is that it is the table 01:$551D's
    // `LD HL,d16` names.
    try testing.expectEqual(@as(u8, 0x21), rom[0x551D]);
    const addr = @as(u16, rom[0x551E]) | (@as(u16, rom[0x551F]) << 8);
    try testing.expectEqual(addr, offsets.find("samus_bombPoseTable").?.gb_addr);
}

test "every HUD constant is the operand of the opcode it was read out of" {
    // Step 13b's. The digit base is added at nine sites and every one is a
    // row, for the reason the bomb test gives: a constant that agrees with one
    // site and not another is two numbers under one name.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstHudBlank", .want = try blocks.loadAt(rom, 0x4950), .from = "01:$4950 LD A,d8" },
        .{ .sym = "ConstHudTankEmpty", .want = try blocks.loadAt(rom, 0x4961), .from = "01:$4961 LD A,d8" },
        .{ .sym = "ConstHudTankFull", .want = try blocks.loadAt(rom, 0x4971), .from = "01:$4971 LD A,d8" },
        .{ .sym = "ConstHudE", .want = try blocks.loadAt(rom, 0x4979), .from = "01:$4979 LD A,d8" },
        .{ .sym = "ConstHudDash", .want = try blocks.loadAt(rom, 0x499D), .from = "01:$499D LD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x49A7), .from = "01:$49A7 ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x49AF), .from = "01:$49AF ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x49BA), .from = "01:$49BA ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x49C4), .from = "01:$49C4 ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x49CC), .from = "01:$49CC ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x49E6), .from = "01:$49E6 ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x49EE), .from = "01:$49EE ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x4A02), .from = "01:$4A02 ADD A,d8" },
        .{ .sym = "ConstHudDigit", .want = try blocks.addAt(rom, 0x4A0B), .from = "01:$4A0B ADD A,d8" },
        .{ .sym = "ConstHudCells", .want = try blocks.loadBIn(rom, 5, 0x4098), .from = "05:$4098 LD B,d8" },
        .{ .sym = "ConstHudWX", .want = try blocks.loadIn(rom, 5, 0x40BC), .from = "05:$40BC LD A,d8" },
        .{ .sym = "ConstHudWX", .want = try blocks.loadAt(rom, 0x4987), .from = "01:$4987 LD A,d8" },
        .{ .sym = "ConstHudWY", .want = try blocks.loadIn(rom, 5, 0x40C0), .from = "05:$40C0 LD A,d8" },
        .{ .sym = "ConstHudWY", .want = try blocks.loadAt(rom, 0x580D), .from = "01:$580D LD A,d8" },
        .{ .sym = "ConstHudWY", .want = try blocks.loadAt(rom, 0x23F8), .from = "00:$23F8 LD A,d8" },
        .{ .sym = "ConstHudWY", .want = try blocks.loadAt(rom, 0x240D), .from = "00:$240D LD A,d8" },
        .{ .sym = "ConstSaveTextCells", .want = try blocks.loadBIn(rom, 5, 0x40A6), .from = "05:$40A6 LD B,d8" },
        .{ .sym = "ConstHudWYUp", .want = try blocks.loadAt(rom, 0x5824), .from = "01:$5824 LD A,d8" },
        .{ .sym = "ConstHudWYUp", .want = try blocks.loadAt(rom, 0x582A), .from = "01:$582A LD A,d8" },
        .{ .sym = "ConstHudWYUp", .want = try blocks.loadAt(rom, 0x3A1F), .from = "00:$3A1F LD A,d8" },
        .{ .sym = "ConstShuffleScramble", .want = try blocks.compareAt(rom, 0x49F6), .from = "01:$49F6 CP d8" },
        .{ .sym = "ConstScrambleTens", .want = try blocks.addAt(rom, 0x49FB), .from = "01:$49FB ADD A,d8" },
        .{ .sym = "ConstHealthOnesMax", .want = try blocks.compareAt(rom, 0x4A30), .from = "01:$4A30 CP d8" },
        .{ .sym = "ConstHealthOnesTop", .want = try blocks.addAt(rom, 0x4A39), .from = "01:$4A39 ADD A,d8" },
        .{ .sym = "ConstHealthTensMax", .want = try blocks.compareAt(rom, 0x4A43), .from = "01:$4A43 CP d8" },
        .{ .sym = "ConstHealthTensTop", .want = try blocks.addAt(rom, 0x4A4C), .from = "01:$4A4C ADD A,d8" },
        .{ .sym = "ConstSfxHealthTick", .want = try blocks.loadAt(rom, 0x4A89), .from = "01:$4A89 LD A,d8" },
        .{ .sym = "ConstSfxHealthTick", .want = try blocks.loadAt(rom, 0x4AAE), .from = "01:$4AAE LD A,d8" },
        .{ .sym = "ConstSfxMissileTick", .want = try blocks.loadAt(rom, 0x4AE3), .from = "01:$4AE3 LD A,d8" },
        .{ .sym = "ConstHudSfxEvery", .want = try blocks.andIn(rom, 1, 0x4A85), .from = "01:$4A85 AND d8" },
        .{ .sym = "ConstHudSfxEvery", .want = try blocks.andIn(rom, 1, 0x4AAA), .from = "01:$4AAA AND d8" },
        .{ .sym = "ConstHudSfxEvery", .want = try blocks.andIn(rom, 1, 0x4AE0), .from = "01:$4AE0 AND d8" },
        .{ .sym = "ConstHudMetY", .want = try blocks.loadAt(rom, 0x4B2C), .from = "01:$4B2C LD A,d8" },
        .{ .sym = "ConstHudMetYUp", .want = try blocks.loadAt(rom, 0x4B47), .from = "01:$4B47 LD A,d8" },
        .{ .sym = "ConstHudMetX", .want = try blocks.loadAt(rom, 0x4B4B), .from = "01:$4B4B LD A,d8" },
        .{ .sym = "ConstItemMajorEnd", .want = try blocks.compareAt(rom, 0x4B43), .from = "01:$4B43 CP d8" },
        .{ .sym = "ConstHudMetFrame", .want = try blocks.andIn(rom, 1, 0x4B56), .from = "01:$4B56 AND d8" },
        .{ .sym = "ConstSprHudMetroid", .want = try blocks.addAt(rom, 0x4B5A), .from = "01:$4B5A ADD A,d8" },
    };

    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print(
                "{s}: engine has ${X:0>2}, the cartridge's {s} says ${X:0>2}\n",
                .{ c.sym, got, c.from, c.want },
            );
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // The two scroll values are arithmetic on the window's corner and the play
    // window's, so they are re-derived here from the cartridge's WX and WY
    // rather than compared with themselves: the pixel the PPU draws at the
    // band's first line and column must be tilemap pixel (0, 0).
    const wx: u16 = try blocks.loadIn(rom, 5, 0x40BC);
    const wy: u16 = try blocks.loadIn(rom, 5, 0x40C0);
    const win_left = (target.screen_w - target.view_w) / 2;
    const band_top = (target.screen_h - target.view_h) / 2;
    const hofs: u16 = @truncate(inject.symbol("ConstHudHofs").?);
    const vofs: u16 = @truncate(inject.symbol("ConstHudVofs").?);
    try testing.expectEqual(@as(u16, 0), (win_left + wx - 7 + hofs) & 0xFF);
    try testing.expectEqual(@as(u16, 0), (band_top + wy + vofs + 1) & 0xFF);
    // And WY is the play area's height, which `snes_target` measured in Step 7
    // by a different route.
    try testing.expectEqual(target.play_h, wy);

    // `hudBaseTilemap` is a physics blob, graded against the ROM by
    // `snes_convert`; this is the `LD HL,d16` at 05:$4092 naming it.
    const o = blocks.offsetIn(5, 0x4092);
    try testing.expectEqual(@as(u8, 0x21), rom[o]);
    const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
    try testing.expectEqual(addr, offsets.find("hudBaseTilemap").?.gb_addr);

    // Step 24g's bar: `saveTextTilemap` by the `LD HL,d16` at 05:$40A0 that
    // copies it to $9C20, and `item_names` by the one at 00:$26AB that `ITEM`'s
    // name arm indexes -- which is also the base the engine subtracts from the
    // table's Game Boy pointers. The length is the arm's `LD A,$10` at $26C3.
    const t = blocks.offsetIn(5, 0x40A0);
    try testing.expectEqualSlices(u8, &.{ 0x21, 0x11, 0x20, 0x9C, 0x06 }, &.{ rom[t], rom[t + 3], rom[t + 4], rom[t + 5], rom[t + 6] });
    try testing.expectEqual(offsets.find("saveTextTilemap").?.gb_addr, std.mem.readInt(u16, rom[t + 1 ..][0..2], .little));
    try testing.expectEqual(@as(usize, rom[t + 7]), offsets.find("saveTextTilemap").?.size);
    try testing.expectEqual(@as(u8, 0x21), rom[0x26AB]);
    const names = std.mem.readInt(u16, rom[0x26AC..][0..2], .little);
    try testing.expectEqual(names, offsets.find("item_names").?.gb_addr);
    try testing.expectEqual(@as(?u32, names), inject.symbol("ConstItemNamesBase"));
    try testing.expectEqual(@as(?u32, try blocks.loadAt(rom, 0x26C3)), inject.symbol("ConstItemNameLen"));
}

test "every explosion and drop constant is the operand of the opcode it was read out of" {
    // Step 12e's nineteen, and the argument for asking the cartridge is the one
    // the projectile block made: these numbers decide how long a corpse is on
    // the screen and what it turns into, and every wrong value among them looks
    // like a design choice rather than a defect. A two-frame explosion is an
    // explosion. A drop that lives 96 frames instead of 176 is a drop.
    //
    // Three of the readers are new and each exists because the site is not a
    // `CP d8`: the ordinary explosion's length is an `LD B,d8`, the blink
    // divisors are `AND d8`, and the three drops are each a single `LD BC,d16`
    // whose two halves are the drop type and the sprite. **The pair is asserted
    // as a pair**, because that is how the cartridge sets it -- a table that had
    // the missile drop's type beside the large-health drop's sprite would be two
    // plausible bytes and one impossible corpse.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const small = try blocks.loadBcIn(rom, 2, 0x5705);
    const large = try blocks.loadBcIn(rom, 2, 0x570A);
    const missile = try blocks.loadBcIn(rom, 2, 0x5700);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        // The flag's own bit, and the two progressions it chooses between.
        .{ .sym = "ConstEnExpBig", .want = @as(u8, 1) << try blocks.bitTestIn(rom, 2, 0x56BF), .from = "02:$56BF BIT n,A" },
        .{ .sym = "ConstSprExpBig", .want = try blocks.addIn(rom, 2, 0x56D5), .from = "02:$56D5 ADD A,d8" },
        .{ .sym = "ConstSprExpNorm", .want = try blocks.addIn(rom, 2, 0x56E2), .from = "02:$56E2 ADD A,d8" },
        .{ .sym = "ConstEnExpBigN", .want = try blocks.compareIn(rom, 2, 0x56D1), .from = "02:$56D1 CP d8" },
        .{ .sym = "ConstEnExpN", .want = try blocks.loadBIn(rom, 2, 0x56C3), .from = "02:$56C3 LD B,d8" },
        .{ .sym = "ConstEnExpShort", .want = try blocks.compareIn(rom, 2, 0x56C5), .from = "02:$56C5 CP d8" },
        // The corpse that is not a corpse.
        .{ .sym = "ConstEnHpRespawn", .want = try blocks.compareIn(rom, 2, 0x56E9), .from = "02:$56E9 CP d8" },
        // The three drops, each as both halves of its own `LD BC,d16`.
        .{ .sym = "ConstEnDropSmall", .want = small.b, .from = "02:$5705 LD BC,d16 (B)" },
        .{ .sym = "ConstSprDropSmall", .want = small.c, .from = "02:$5705 LD BC,d16 (C)" },
        .{ .sym = "ConstEnDropLarge", .want = large.b, .from = "02:$570A LD BC,d16 (B)" },
        .{ .sym = "ConstSprDropLarge", .want = large.c, .from = "02:$570A LD BC,d16 (C)" },
        .{ .sym = "ConstEnDropMissile", .want = missile.b, .from = "02:$5700 LD BC,d16 (B)" },
        .{ .sym = "ConstSprDropMissile", .want = missile.c, .from = "02:$5700 LD BC,d16 (C)" },
        // And how long a drop waits, and how fast it blinks while it does.
        .{ .sym = "ConstEnDropLife", .want = try blocks.compareIn(rom, 2, 0x5697), .from = "02:$5697 CP d8" },
        .{ .sym = "ConstEnDropFast", .want = try blocks.compareIn(rom, 2, 0x569B), .from = "02:$569B CP d8" },
        .{ .sym = "ConstEnDropSlowM", .want = try blocks.andIn(rom, 2, 0x56A1), .from = "02:$56A1 AND d8" },
        .{ .sym = "ConstEnDropFastM", .want = try blocks.andIn(rom, 2, 0x56A8), .from = "02:$56A8 AND d8" },
        .{ .sym = "ConstEnDropBlink", .want = try blocks.xorIn(rom, 2, 0x56AF), .from = "02:$56AF XOR d8" },
        // The mask of the roll. **The register it masks is substituted and the
        // mask is not**, which is exactly why it is pinned here: `!EnFrame`
        // stands in for `rDIV`, and a reader who finds the mask graded against
        // the cartridge is a reader who can see that the mask was not the part
        // that changed.
        .{ .sym = "ConstEnDropRoll", .want = try blocks.andIn(rom, 2, 0x56F0), .from = "02:$56F0 AND d8" },
    };

    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print(
                "{s}: engine has ${X:0>2}, the cartridge's {s} says ${X:0>2}\n",
                .{ c.sym, got, c.from, c.want },
            );
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "every enemy AI constant and table is the operand or the bytes it was read out of" {
    // Step 12f's. The hopper's arc is two sixteen-byte tables and five
    // operands, and a wrong one is a hopper that jumps a pixel short -- which
    // the enemy oracle would catch as a disagreement without saying which
    // number was wrong. This says which.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstEnBgDown", .want = try blocks.loadIn(rom, 2, 0x4A28), .from = "02:$4A28 LD A,d8" },
        .{ .sym = "ConstEnBgRight", .want = try blocks.loadIn(rom, 2, 0x4783), .from = "02:$4783 LD A,d8" },
        .{ .sym = "ConstEnBgLeft", .want = try blocks.loadIn(rom, 2, 0x495C), .from = "02:$495C LD A,d8" },
        .{ .sym = "ConstEnBgUp", .want = try blocks.loadIn(rom, 2, 0x4D51), .from = "02:$4D51 LD A,d8" },
        .{ .sym = "ConstRockSprIdle1", .want = try blocks.loadIn(rom, 2, 0x5563), .from = "02:$5563 LD A,d8" },
        .{ .sym = "ConstRockSprIdle2", .want = try blocks.loadIn(rom, 2, 0x5574), .from = "02:$5574 LD A,d8" },
        .{ .sym = "ConstRockSprMove1", .want = try blocks.loadIn(rom, 2, 0x55A1), .from = "02:$55A1 LD A,d8" },
        .{ .sym = "ConstRockIdleN", .want = try blocks.compareIn(rom, 2, 0x556C), .from = "02:$556C CP d8" },
        .{ .sym = "ConstRockWaitN", .want = try blocks.compareIn(rom, 2, 0x5584), .from = "02:$5584 CP d8" },
        .{ .sym = "ConstRockEdgeM", .want = try blocks.andIn(rom, 2, 0x5595), .from = "02:$5595 AND d8" },
        .{ .sym = "ConstRockEdgeN", .want = try blocks.compareIn(rom, 2, 0x559E), .from = "02:$559E CP d8" },
        .{ .sym = "ConstRockHangN", .want = try blocks.compareIn(rom, 2, 0x55C2), .from = "02:$55C2 CP d8" },
        .{ .sym = "ConstRockDropM", .want = try blocks.andIn(rom, 2, 0x55D2), .from = "02:$55D2 AND d8" },
        .{ .sym = "ConstRockFall", .want = try blocks.addIn(rom, 2, 0x55E2), .from = "02:$55E2 ADD A,d8" },
        .{ .sym = "ConstRockFloorY", .want = try blocks.compareIn(rom, 2, 0x55F7), .from = "02:$55F7 CP d8" },
        .{ .sym = "ConstSfxHitGround", .want = try blocks.loadIn(rom, 2, 0x55FA), .from = "02:$55FA LD A,d8" },
        .{ .sym = "ConstGulSpr3", .want = try blocks.compareIn(rom, 2, 0x5E02), .from = "02:$5E02 CP d8" },
        .{ .sym = "ConstGulEnd", .want = try blocks.compareIn(rom, 2, 0x5CEE), .from = "02:$5CEE CP d8" },
        .{ .sym = "ConstLeechNear", .want = try blocks.compareIn(rom, 2, 0x5E20), .from = "02:$5E20 CP d8" },
        .{ .sym = "ConstLeechRiseN", .want = try blocks.compareIn(rom, 2, 0x5E41), .from = "02:$5E41 CP d8" },
        .{ .sym = "ConstLeechRise", .want = try blocks.subIn(rom, 2, 0x5E49), .from = "02:$5E49 SUB d8" },
        .{ .sym = "ConstLeechEnd", .want = try blocks.compareIn(rom, 2, 0x5E71), .from = "02:$5E71 CP d8" },
        .{ .sym = "ConstLeechHangN", .want = try blocks.compareIn(rom, 2, 0x5E92), .from = "02:$5E92 CP d8" },
        .{ .sym = "ConstSprOctroll1", .want = try blocks.compareIn(rom, 2, 0x5E2E), .from = "02:$5E2E CP d8" },
        .{ .sym = "ConstAccelLast", .want = try blocks.compareIn(rom, 2, 0x6A82), .from = "02:$6A82 CP d8" },
        .{ .sym = "ConstPipeWaitN", .want = try blocks.compareIn(rom, 2, 0x5F76), .from = "02:$5F76 CP d8" },
        .{ .sym = "ConstPipeBugsN", .want = try blocks.compareIn(rom, 2, 0x5F7F), .from = "02:$5F7F CP d8" },
        .{ .sym = "ConstSfxPipeStop", .want = try blocks.loadIn(rom, 2, 0x5F86), .from = "02:$5F86 LD A,d8" },
        .{ .sym = "ConstSprYumeePipe", .want = try blocks.compareIn(rom, 2, 0x5F9E), .from = "02:$5F9E CP d8" },
        .{ .sym = "ConstSprGawron1", .want = try blocks.loadIn(rom, 2, 0x5FA2), .from = "02:$5FA2 LD A,d8" },
        .{ .sym = "ConstSprYumee1", .want = try blocks.loadIn(rom, 2, 0x5FA6), .from = "02:$5FA6 LD A,d8" },
        .{ .sym = "ConstGawronFlip", .want = try blocks.xorIn(rom, 2, 0x60A3), .from = "02:$60A3 XOR d8" },
        .{ .sym = "ConstYumeeFlip", .want = try blocks.xorIn(rom, 2, 0x60A7), .from = "02:$60A7 XOR d8" },
        .{ .sym = "ConstPipeNear", .want = try blocks.compareIn(rom, 2, 0x6028), .from = "02:$6028 CP d8" },
        .{ .sym = "ConstPipeRise", .want = try blocks.subIn(rom, 2, 0x6042), .from = "02:$6042 SUB d8" },
        .{ .sym = "ConstPipeLevel", .want = try blocks.addIn(rom, 2, 0x6048), .from = "02:$6048 ADD A,d8" },
        .{ .sym = "ConstPipeGoneX", .want = try blocks.compareIn(rom, 2, 0x605E), .from = "02:$605E CP d8" },
        .{ .sym = "ConstSprWallfireFlip", .want = try blocks.compareIn(rom, 2, 0x62B8), .from = "02:$62B8 CP d8" },
        .{ .sym = "ConstSprWallfireDead", .want = try blocks.compareIn(rom, 2, 0x62CB), .from = "02:$62CB CP d8" },
        .{ .sym = "ConstEnTouch", .want = try blocks.compareIn(rom, 2, 0x62D1), .from = "02:$62D1 CP d8" },
        .{ .sym = "ConstSfxEnemyKilled", .want = try blocks.loadIn(rom, 2, 0x62DD), .from = "02:$62DD LD A,d8" },
        .{ .sym = "ConstSprWallfire2", .want = try blocks.compareIn(rom, 2, 0x62E4), .from = "02:$62E4 CP d8" },
        .{ .sym = "ConstWallfireWaitN", .want = try blocks.compareIn(rom, 2, 0x62ED), .from = "02:$62ED CP d8" },
        .{ .sym = "ConstWallfireShotDy", .want = try blocks.subIn(rom, 2, 0x62F9), .from = "02:$62F9 SUB d8" },
        .{ .sym = "ConstWallfireShotDx", .want = try blocks.addIn(rom, 2, 0x6305), .from = "02:$6305 ADD A,d8" },
        .{ .sym = "ConstSprWallfireShot1", .want = try blocks.loadIn(rom, 2, 0x630E), .from = "02:$630E LD A,d8" },
        .{ .sym = "ConstSfxEnemyShot", .want = try blocks.loadIn(rom, 2, 0x6325), .from = "02:$6325 LD A,d8" },
        .{ .sym = "ConstWallfireOpenN", .want = try blocks.compareIn(rom, 2, 0x6330), .from = "02:$6330 CP d8" },
        .{ .sym = "ConstSprWallfireShot3", .want = try blocks.compareIn(rom, 2, 0x633E), .from = "02:$633E CP d8" },
        .{ .sym = "ConstWallfireShotV", .want = try blocks.addIn(rom, 2, 0x634F), .from = "02:$634F ADD A,d8" },
        .{ .sym = "ConstSfxEnemyBurst", .want = try blocks.loadIn(rom, 2, 0x635F), .from = "02:$635F LD A,d8" },
        .{ .sym = "ConstSprWallfireShot4", .want = try blocks.compareIn(rom, 2, 0x6374), .from = "02:$6374 CP d8" },
        .{ .sym = "ConstSprMissileDoor", .want = try blocks.compareIn(rom, 2, 0x6A1B), .from = "02:$6A1B CP d8" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x6A26), .from = "02:$6A26 LD A,d8" },
        .{ .sym = "ConstWpnMissile", .want = try blocks.compareIn(rom, 2, 0x6A2C), .from = "02:$6A2C CP d8, the missile door's second statement of it" },
        .{ .sym = "ConstSfxMissileHit", .want = try blocks.loadIn(rom, 2, 0x6A34), .from = "02:$6A34 LD A,d8" },
        .{ .sym = "ConstDoorFlash", .want = try blocks.loadIn(rom, 2, 0x6A39), .from = "02:$6A39 LD A,d8" },
        .{ .sym = "ConstDoorMissilesN", .want = try blocks.compareIn(rom, 2, 0x6A42), .from = "02:$6A42 CP d8" },
        .{ .sym = "ConstSfxDoorBlown", .want = try blocks.loadIn(rom, 2, 0x6A4D), .from = "02:$6A4D LD A,d8" },
        .{ .sym = "ConstDoorBlastDx", .want = try blocks.subIn(rom, 2, 0x6A5D), .from = "02:$6A5D SUB d8" },
        .{ .sym = "ConstSprAlpha1", .want = try blocks.loadIn(rom, 2, 0x6BD8), .from = "02:$6BD8 LD A,d8" },
        .{ .sym = "ConstSprAlpha1", .want = try blocks.loadIn(rom, 2, 0x6C4F), .from = "02:$6C4F LD A,d8, the in-range test" },
        .{ .sym = "ConstSprAlpha1", .want = try blocks.loadIn(rom, 2, 0x6CA7), .from = "02:$6CA7 LD A,d8, the knockback done" },
        .{ .sym = "ConstSprAlphaFace", .want = try blocks.compareIn(rom, 2, 0x6BF4), .from = "02:$6BF4 CP d8" },
        .{ .sym = "ConstSprAlphaFace", .want = try blocks.loadIn(rom, 2, 0x6DB0), .from = "02:$6DB0 LD A,d8" },
        .{ .sym = "ConstAlphaAnim", .want = try blocks.xorIn(rom, 2, 0x6E3D), .from = "02:$6E3D XOR d8" },
        .{ .sym = "ConstAlphaFlash", .want = try blocks.xorIn(rom, 2, 0x6C06), .from = "02:$6C06 XOR d8" },
        .{ .sym = "ConstAlphaFlash", .want = try blocks.xorIn(rom, 2, 0x6C3F), .from = "02:$6C3F XOR d8, the frozen flash" },
        .{ .sym = "ConstAlphaRange", .want = try blocks.compareIn(rom, 2, 0x6C15), .from = "02:$6C15 CP d8" },
        .{ .sym = "ConstAlphaRange", .want = try blocks.compareIn(rom, 2, 0x6C5E), .from = "02:$6C5E CP d8, the seen Alpha" },
        .{ .sym = "ConstMetStateFight", .want = try blocks.compareIn(rom, 2, 0x6BDF), .from = "02:$6BDF CP d8" },
        .{ .sym = "ConstMetStateFight", .want = try blocks.loadIn(rom, 2, 0x6C6A), .from = "02:$6C6A LD A,d8" },
        .{ .sym = "ConstMetStateFight", .want = try blocks.loadIn(rom, 2, 0x6DA6), .from = "02:$6DA6 LD A,d8" },
        .{ .sym = "ConstMetStateStart", .want = try blocks.compareIn(rom, 2, 0x6BED), .from = "02:$6BED CP d8" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x6C28), .from = "02:$6C28 LD A,d8" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.compareIn(rom, 2, 0x6C25), .from = "02:$6C25 CP d8, the songPlaying guard" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x6C76), .from = "02:$6C76 LD A,d8, the seen Alpha" },
        .{ .sym = "ConstAlphaFaceN", .want = try blocks.compareIn(rom, 2, 0x6C38), .from = "02:$6C38 CP d8" },
        .{ .sym = "ConstAlphaRise", .want = try blocks.subIn(rom, 2, 0x6DC1), .from = "02:$6DC1 SUB d8" },
        .{ .sym = "ConstAlphaRiseN", .want = try blocks.compareIn(rom, 2, 0x6DC9), .from = "02:$6DC9 CP d8" },
        .{ .sym = "ConstAlphaLungeN", .want = try blocks.compareIn(rom, 2, 0x6CD6), .from = "02:$6CD6 CP d8" },
        .{ .sym = "ConstAlphaPauseN", .want = try blocks.compareIn(rom, 2, 0x6CDA), .from = "02:$6CDA CP d8" },
        // 1.0 Step 14: the Gamma's, and its angle's slope bands in bank 1.
        .{ .sym = "ConstSprGamma1", .want = try blocks.loadIn(rom, 2, 0x6FD8), .from = "02:$6FD8 LD A,d8, the seen Gamma" },
        .{ .sym = "ConstSprGamma1", .want = try blocks.loadIn(rom, 2, 0x7005), .from = "02:$7005 LD A,d8, the molt's end" },
        .{ .sym = "ConstSprGamma1", .want = try blocks.loadIn(rom, 2, 0x715A), .from = "02:$715A LD A,d8, the screw knockback's end" },
        .{ .sym = "ConstSprGamma2", .want = try blocks.loadIn(rom, 2, 0x718E), .from = "02:$718E LD A,d8" },
        .{ .sym = "ConstSprGammaBolt", .want = try blocks.loadIn(rom, 2, 0x71B1), .from = "02:$71B1 LD A,d8" },
        .{ .sym = "ConstSprGammaBolt", .want = try blocks.compareIn(rom, 2, 0x71E3), .from = "02:$71E3 CP d8, the bolt's first step" },
        .{ .sym = "ConstGammaMolt", .want = try blocks.xorIn(rom, 2, 0x6FD3), .from = "02:$6FD3 XOR d8" },
        .{ .sym = "ConstGammaMoltN", .want = try blocks.compareIn(rom, 2, 0x6FCC), .from = "02:$6FCC CP d8" },
        .{ .sym = "ConstGammaRange", .want = try blocks.compareIn(rom, 2, 0x6FB0), .from = "02:$6FB0 CP d8" },
        .{ .sym = "ConstGammaRange", .want = try blocks.compareIn(rom, 2, 0x6FE7), .from = "02:$6FE7 CP d8, the seen Gamma" },
        .{ .sym = "ConstGammaStunN", .want = try blocks.loadIn(rom, 2, 0x7056), .from = "02:$7056 LD A,d8" },
        .{ .sym = "ConstGammaKnock", .want = try blocks.subIn(rom, 2, 0x7077), .from = "02:$7077 SUB d8, up" },
        .{ .sym = "ConstGammaKnock", .want = try blocks.addIn(rom, 2, 0x709C), .from = "02:$709C ADD A,d8, down" },
        .{ .sym = "ConstGammaKnock", .want = try blocks.addIn(rom, 2, 0x70BE), .from = "02:$70BE ADD A,d8, right" },
        .{ .sym = "ConstGammaKnock", .want = try blocks.subIn(rom, 2, 0x70E3), .from = "02:$70E3 SUB d8, left" },
        .{ .sym = "ConstGammaKnockTop", .want = try blocks.compareIn(rom, 2, 0x7079), .from = "02:$7079 CP d8, up" },
        .{ .sym = "ConstGammaKnockTop", .want = try blocks.compareIn(rom, 2, 0x70DF), .from = "02:$70DF CP d8, left" },
        .{ .sym = "ConstGammaLungeN", .want = try blocks.compareIn(rom, 2, 0x7184), .from = "02:$7184 CP d8" },
        .{ .sym = "ConstGammaFireN", .want = try blocks.compareIn(rom, 2, 0x7193), .from = "02:$7193 CP d8" },
        .{ .sym = "ConstGammaBoltDy", .want = try blocks.addIn(rom, 2, 0x719D), .from = "02:$719D ADD A,d8" },
        .{ .sym = "ConstGammaBoltDx", .want = try blocks.subIn(rom, 2, 0x71A8), .from = "02:$71A8 SUB d8" },
        .{ .sym = "ConstGammaBoltDx", .want = try blocks.addIn(rom, 2, 0x71AE), .from = "02:$71AE ADD A,d8" },
        .{ .sym = "ConstGammaBoltUp1", .want = try blocks.subIn(rom, 2, 0x7211), .from = "02:$7211 SUB d8" },
        .{ .sym = "ConstGammaBoltUp2", .want = try blocks.subIn(rom, 2, 0x71F0), .from = "02:$71F0 SUB d8" },
        .{ .sym = "ConstGammaBoltStep", .want = try blocks.addIn(rom, 2, 0x71FC), .from = "02:$71FC ADD A,d8" },
        .{ .sym = "ConstGammaBoltStep", .want = try blocks.subIn(rom, 2, 0x7203), .from = "02:$7203 SUB d8" },
        .{ .sym = "ConstGammaBoltStep", .want = try blocks.subIn(rom, 2, 0x721D), .from = "02:$721D SUB d8" },
        .{ .sym = "ConstGammaBoltStep", .want = try blocks.addIn(rom, 2, 0x7224), .from = "02:$7224 ADD A,d8" },
        .{ .sym = "ConstSfxGammaBolt", .want = try blocks.loadIn(rom, 2, 0x71CA), .from = "02:$71CA LD A,d8" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x6F79), .from = "02:$6F79 LD A,d8, the stunned Gamma" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x7028), .from = "02:$7028 LD A,d8, the Gamma's bolt" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x703E), .from = "02:$703E LD A,d8, the fighting Gamma" },
        .{ .sym = "ConstSfxMetroidScrew", .want = try blocks.loadIn(rom, 2, 0x7047), .from = "02:$7047 LD A,d8, the Gamma's" },
        .{ .sym = "ConstSfxMetroidHurt", .want = try blocks.loadIn(rom, 2, 0x705B), .from = "02:$705B LD A,d8, the Gamma's" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x6F76), .from = "02:$6F76 CP d8, the stunned Gamma" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x7025), .from = "02:$7025 CP d8, the Gamma's bolt" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x7036), .from = "02:$7036 CP d8, the fighting Gamma" },
        .{ .sym = "ConstWpnMissile", .want = try blocks.compareIn(rom, 2, 0x703A), .from = "02:$703A CP d8, the Gamma's hurt test" },
        .{ .sym = "ConstEnTouch", .want = try blocks.compareIn(rom, 2, 0x7031), .from = "02:$7031 CP d8, the Gamma's" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x6FB8), .from = "02:$6FB8 LD A,d8, the molt" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.compareIn(rom, 2, 0x6FFA), .from = "02:$6FFA CP d8, the seen Gamma's songPlaying guard" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x6FFD), .from = "02:$6FFD LD A,d8, the seen Gamma" },
        .{ .sym = "ConstMetOrigin", .want = try blocks.addIn(rom, 2, 0x716D), .from = "02:$716D ADD A,d8, the Gamma's facing test" },
        .{ .sym = "ConstMetStateDying", .want = try blocks.loadIn(rom, 2, 0x710A), .from = "02:$710A LD A,d8, the Gamma's death" },
        .{ .sym = "ConstSprExpBig", .want = try blocks.loadIn(rom, 2, 0x710F), .from = "02:$710F LD A,d8, the Gamma's death" },
        .{ .sym = "ConstSfxMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x7113), .from = "02:$7113 LD A,d8, the Gamma's" },
        .{ .sym = "ConstSongMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x7118), .from = "02:$7118 LD A,d8, the Gamma's" },
        .{ .sym = "ConstMetFightDied", .want = try blocks.loadIn(rom, 2, 0x711D), .from = "02:$711D LD A,d8, the Gamma's" },
        .{ .sym = "ConstMetShuffle", .want = try blocks.loadIn(rom, 2, 0x7134), .from = "02:$7134 LD A,d8, the Gamma's" },
        .{ .sym = "ConstGSlope1", .want = try blocks.compareIn(rom, 1, 0x72C5), .from = "01:$72C5 CP d8" },
        .{ .sym = "ConstGSlope2", .want = try blocks.compareIn(rom, 1, 0x72C9), .from = "01:$72C9 CP d8" },
        .{ .sym = "ConstGSlope3", .want = try blocks.compareIn(rom, 1, 0x72CD), .from = "01:$72CD CP d8" },
        .{ .sym = "ConstGSlope4", .want = try blocks.compareIn(rom, 1, 0x72D1), .from = "01:$72D1 CP d8" },
        .{ .sym = "ConstGSlopeHi3", .want = try blocks.compareIn(rom, 1, 0x72D7), .from = "01:$72D7 CP d8" },
        .{ .sym = "ConstGSlopeHi1", .want = try blocks.compareIn(rom, 1, 0x72DD), .from = "01:$72DD CP d8" },
        .{ .sym = "ConstGSlopeHi3Lo", .want = try blocks.compareIn(rom, 1, 0x72E8), .from = "01:$72E8 CP d8" },
        .{ .sym = "ConstGSlopeHi1Lo", .want = try blocks.compareIn(rom, 1, 0x72F1), .from = "01:$72F1 CP d8" },
        // 1.0 Step 15: the Zeta's, its husk's and its fireball's.
        .{ .sym = "ConstSprZetaHusk", .want = try blocks.subIn(rom, 2, 0x72C9), .from = "02:$72C9 SUB d8, the husk's test" },
        .{ .sym = "ConstSprZetaHusk", .want = try blocks.loadHlIn(rom, 2, 0x7621), .from = "02:$7621 LD (HL),d8, the tail's wrap" },
        .{ .sym = "ConstSprZeta1", .want = try blocks.loadIn(rom, 2, 0x74F9), .from = "02:$74F9 LD A,d8, the rise's end" },
        .{ .sym = "ConstSprZeta1", .want = try blocks.loadIn(rom, 2, 0x757A), .from = "02:$757A LD A,d8, the husk shed" },
        .{ .sym = "ConstSprZeta4", .want = try blocks.compareIn(rom, 2, 0x761D), .from = "02:$761D CP d8" },
        .{ .sym = "ConstSprZeta5", .want = try blocks.loadIn(rom, 2, 0x72A7), .from = "02:$72A7 LD A,d8, the stun's end" },
        .{ .sym = "ConstSprZeta5", .want = try blocks.loadIn(rom, 2, 0x7317), .from = "02:$7317 LD A,d8, the seen Zeta" },
        .{ .sym = "ConstSprZeta5", .want = try blocks.loadIn(rom, 2, 0x735F), .from = "02:$735F LD A,d8, the screw knockback's end" },
        .{ .sym = "ConstSprZeta5", .want = try blocks.compareIn(rom, 2, 0x74A3), .from = "02:$74A3 CP d8, the spit's end" },
        .{ .sym = "ConstSprZeta5", .want = try blocks.loadIn(rom, 2, 0x7516), .from = "02:$7516 LD A,d8, the wait's end" },
        .{ .sym = "ConstSprZeta5", .want = try blocks.loadHlIn(rom, 2, 0x751E), .from = "02:$751E LD (HL),d8, the fight's start" },
        .{ .sym = "ConstSprZeta6", .want = try blocks.loadIn(rom, 2, 0x73C7), .from = "02:$73C7 LD A,d8" },
        .{ .sym = "ConstSprZeta8", .want = try blocks.loadIn(rom, 2, 0x73FB), .from = "02:$73FB LD A,d8" },
        .{ .sym = "ConstSprZeta8", .want = try blocks.loadHlIn(rom, 2, 0x762D), .from = "02:$762D LD (HL),d8" },
        .{ .sym = "ConstSprZetaB", .want = try blocks.compareIn(rom, 2, 0x7629), .from = "02:$7629 CP d8" },
        .{ .sym = "ConstSprZetaShot", .want = try blocks.loadIn(rom, 2, 0x75C9), .from = "02:$75C9 LD A,d8" },
        .{ .sym = "ConstZetaRange", .want = try blocks.compareIn(rom, 2, 0x72EE), .from = "02:$72EE CP d8" },
        .{ .sym = "ConstZetaRange", .want = try blocks.compareIn(rom, 2, 0x7326), .from = "02:$7326 CP d8, the seen Zeta" },
        .{ .sym = "ConstZetaHuskN", .want = try blocks.compareIn(rom, 2, 0x730B), .from = "02:$730B CP d8" },
        .{ .sym = "ConstZetaVec0", .want = try blocks.loadIn(rom, 2, 0x72AB), .from = "02:$72AB LD A,d8, the stun's end" },
        .{ .sym = "ConstZetaVec0", .want = try blocks.loadIn(rom, 2, 0x7329), .from = "02:$7329 LD A,d8, the seen Zeta" },
        .{ .sym = "ConstZetaVec0", .want = try blocks.loadIn(rom, 2, 0x7363), .from = "02:$7363 LD A,d8, the screw knockback's end" },
        .{ .sym = "ConstZetaVec0", .want = try blocks.loadIn(rom, 2, 0x7520), .from = "02:$7520 LD A,d8, the fight's start" },
        .{ .sym = "ConstZetaHuskGone", .want = try blocks.compareIn(rom, 2, 0x72C2), .from = "02:$72C2 CP d8" },
        .{ .sym = "ConstZetaHuskGone", .want = try blocks.loadIn(rom, 2, 0x7553), .from = "02:$7553 LD A,d8" },
        .{ .sym = "ConstZetaChase", .want = try blocks.compareIn(rom, 2, 0x72B4), .from = "02:$72B4 CP d8" },
        .{ .sym = "ConstZetaChase", .want = try blocks.loadIn(rom, 2, 0x7338), .from = "02:$7338 LD A,d8, the seen Zeta" },
        .{ .sym = "ConstZetaChase", .want = try blocks.loadIn(rom, 2, 0x7369), .from = "02:$7369 LD A,d8, the screw knockback's end" },
        .{ .sym = "ConstZetaChase", .want = try blocks.loadIn(rom, 2, 0x750D), .from = "02:$750D LD A,d8, the wait's end" },
        .{ .sym = "ConstZetaChase", .want = try blocks.loadIn(rom, 2, 0x752E), .from = "02:$752E LD A,d8, the fight's start" },
        .{ .sym = "ConstZetaSpit", .want = try blocks.compareIn(rom, 2, 0x7372), .from = "02:$7372 CP d8" },
        .{ .sym = "ConstZetaSpit", .want = try blocks.loadIn(rom, 2, 0x73BD), .from = "02:$73BD LD A,d8" },
        .{ .sym = "ConstZetaRise", .want = try blocks.compareIn(rom, 2, 0x748D), .from = "02:$748D CP d8" },
        .{ .sym = "ConstZetaRise", .want = try blocks.loadIn(rom, 2, 0x74B2), .from = "02:$74B2 LD A,d8" },
        .{ .sym = "ConstZetaWait", .want = try blocks.compareIn(rom, 2, 0x7491), .from = "02:$7491 CP d8" },
        .{ .sym = "ConstZetaWait", .want = try blocks.compareIn(rom, 2, 0x74BB), .from = "02:$74BB CP d8, the fireball" },
        .{ .sym = "ConstZetaWait", .want = try blocks.loadIn(rom, 2, 0x74F1), .from = "02:$74F1 LD A,d8" },
        .{ .sym = "ConstZetaNear", .want = try blocks.compareIn(rom, 2, 0x7388), .from = "02:$7388 CP d8, across" },
        .{ .sym = "ConstZetaNear", .want = try blocks.compareIn(rom, 2, 0x73B3), .from = "02:$73B3 CP d8, below" },
        .{ .sym = "ConstZetaNearL", .want = try blocks.compareIn(rom, 2, 0x7397), .from = "02:$7397 CP d8" },
        .{ .sym = "ConstZetaStunN", .want = try blocks.loadIn(rom, 2, 0x73FF), .from = "02:$73FF LD A,d8" },
        .{ .sym = "ConstZetaKnock", .want = try blocks.addIn(rom, 2, 0x741E), .from = "02:$741E ADD A,d8, down" },
        .{ .sym = "ConstZetaKnock", .want = try blocks.addIn(rom, 2, 0x7433), .from = "02:$7433 ADD A,d8, right" },
        .{ .sym = "ConstZetaKnock", .want = try blocks.subIn(rom, 2, 0x743B), .from = "02:$743B SUB d8, left" },
        .{ .sym = "ConstZetaKnockLeft", .want = try blocks.compareIn(rom, 2, 0x743D), .from = "02:$743D CP d8" },
        .{ .sym = "ConstZetaTop", .want = try blocks.compareIn(rom, 2, 0x74E3), .from = "02:$74E3 CP d8" },
        .{ .sym = "ConstZetaWaitN", .want = try blocks.compareIn(rom, 2, 0x7503), .from = "02:$7503 CP d8" },
        .{ .sym = "ConstZetaRiseN", .want = try blocks.compareIn(rom, 2, 0x7595), .from = "02:$7595 CP d8" },
        .{ .sym = "ConstZetaHuskDy", .want = try blocks.subIn(rom, 2, 0x7577), .from = "02:$7577 SUB d8" },
        .{ .sym = "ConstZetaHuskPal", .want = try blocks.loadIn(rom, 2, 0x753E), .from = "02:$753E LD A,d8" },
        .{ .sym = "ConstZetaHuskFlag", .want = try blocks.loadIn(rom, 2, 0x756B), .from = "02:$756B LD A,d8" },
        .{ .sym = "ConstZetaBottom", .want = try blocks.compareIn(rom, 2, 0x7549), .from = "02:$7549 CP d8, the husk" },
        .{ .sym = "ConstZetaBottom", .want = try blocks.compareIn(rom, 2, 0x74C5), .from = "02:$74C5 CP d8, the fireball" },
        .{ .sym = "ConstZetaShotDy", .want = try blocks.addIn(rom, 2, 0x74C3), .from = "02:$74C3 ADD A,d8" },
        .{ .sym = "ConstZetaShotOy", .want = try blocks.addIn(rom, 2, 0x75B3), .from = "02:$75B3 ADD A,d8" },
        .{ .sym = "ConstZetaShotOx", .want = try blocks.subIn(rom, 2, 0x75BF), .from = "02:$75BF SUB d8" },
        .{ .sym = "ConstZetaShotOx", .want = try blocks.addIn(rom, 2, 0x75C6), .from = "02:$75C6 ADD A,d8" },
        .{ .sym = "ConstZetaShotBase", .want = try blocks.loadIn(rom, 2, 0x75CC), .from = "02:$75CC LD A,d8" },
        .{ .sym = "ConstSfxZetaShot", .want = try blocks.loadIn(rom, 2, 0x75DC), .from = "02:$75DC LD A,d8" },
        .{ .sym = "ConstSeekStep", .want = try blocks.loadBIn(rom, 2, 0x7377), .from = "02:$7377 LD B,d8" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x729A), .from = "02:$729A LD A,d8, the stunned Zeta" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x73DC), .from = "02:$73DC LD A,d8, the fighting Zeta" },
        .{ .sym = "ConstSfxMetroidScrew", .want = try blocks.loadIn(rom, 2, 0x73E5), .from = "02:$73E5 LD A,d8, the Zeta's" },
        .{ .sym = "ConstSfxMetroidHurt", .want = try blocks.loadIn(rom, 2, 0x7404), .from = "02:$7404 LD A,d8, the Zeta's" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x7297), .from = "02:$7297 CP d8, the stunned Zeta" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x73D4), .from = "02:$73D4 CP d8, the fighting Zeta" },
        .{ .sym = "ConstWpnMissile", .want = try blocks.compareIn(rom, 2, 0x73D8), .from = "02:$73D8 CP d8, the Zeta's hurt test" },
        .{ .sym = "ConstEnTouch", .want = try blocks.compareIn(rom, 2, 0x73CF), .from = "02:$73CF CP d8, the Zeta's" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x72F6), .from = "02:$72F6 LD A,d8, the intro" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.compareIn(rom, 2, 0x7340), .from = "02:$7340 CP d8, the seen Zeta's songPlaying guard" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x7344), .from = "02:$7344 LD A,d8, the seen Zeta" },
        .{ .sym = "ConstMetStateDying", .want = try blocks.loadIn(rom, 2, 0x7457), .from = "02:$7457 LD A,d8, the Zeta's death" },
        .{ .sym = "ConstSprExpBig", .want = try blocks.loadIn(rom, 2, 0x745C), .from = "02:$745C LD A,d8, the Zeta's death" },
        .{ .sym = "ConstSfxMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x7460), .from = "02:$7460 LD A,d8, the Zeta's" },
        .{ .sym = "ConstSongMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x7465), .from = "02:$7465 LD A,d8, the Zeta's" },
        .{ .sym = "ConstMetFightDied", .want = try blocks.loadIn(rom, 2, 0x746A), .from = "02:$746A LD A,d8, the Zeta's" },
        .{ .sym = "ConstMetShuffle", .want = try blocks.loadIn(rom, 2, 0x7481), .from = "02:$7481 LD A,d8, the Zeta's" },
        .{ .sym = "ConstSeekBias", .want = try blocks.addIn(rom, 3, 0x6B4A), .from = "03:$6B4A ADD A,d8, Samus's X" },
        .{ .sym = "ConstSeekBias", .want = try blocks.addIn(rom, 3, 0x6B50), .from = "03:$6B50 ADD A,d8, Samus's Y" },
        .{ .sym = "ConstSeekBias", .want = try blocks.addIn(rom, 3, 0x6B55), .from = "03:$6B55 ADD A,d8, the enemy's X" },
        .{ .sym = "ConstSeekBias", .want = try blocks.addIn(rom, 3, 0x6B5A), .from = "03:$6B5A ADD A,d8, the enemy's Y" },
        // 1.0 Step 16: the Omega's and its fireball's.
        .{ .sym = "ConstSprOmega1", .want = try blocks.loadIn(rom, 2, 0x7771), .from = "02:$7771 LD A,d8, the mouth shut" },
        .{ .sym = "ConstSprOmega1", .want = try blocks.loadIn(rom, 2, 0x781F), .from = "02:$781F LD A,d8, the rise's end" },
        .{ .sym = "ConstSprOmega1", .want = try blocks.loadIn(rom, 2, 0x7950), .from = "02:$7950 LD A,d8, the seen Omega" },
        .{ .sym = "ConstSprOmega1", .want = try blocks.loadIn(rom, 2, 0x798D), .from = "02:$798D LD A,d8, the fight's start" },
        .{ .sym = "ConstSprOmega3", .want = try blocks.loadIn(rom, 2, 0x783D), .from = "02:$783D LD A,d8" },
        .{ .sym = "ConstSprOmega5", .want = try blocks.loadIn(rom, 2, 0x7748), .from = "02:$7748 LD A,d8, the screw knockback's end" },
        .{ .sym = "ConstSprOmega5", .want = try blocks.loadIn(rom, 2, 0x79F6), .from = "02:$79F6 LD A,d8, the chase's pick" },
        .{ .sym = "ConstSprOmegaHurt", .want = try blocks.loadHlIn(rom, 2, 0x76C5), .from = "02:$76C5 LD (HL),d8" },
        .{ .sym = "ConstSprOmegaShot", .want = try blocks.loadIn(rom, 2, 0x793D), .from = "02:$793D LD A,d8" },
        .{ .sym = "ConstSprOmegaBurst", .want = try blocks.compareIn(rom, 2, 0x7851), .from = "02:$7851 CP d8" },
        .{ .sym = "ConstSprOmegaBurst", .want = try blocks.loadIn(rom, 2, 0x78B4), .from = "02:$78B4 LD A,d8" },
        .{ .sym = "ConstSprOmegaBurstEnd", .want = try blocks.compareIn(rom, 2, 0x78BD), .from = "02:$78BD CP d8" },
        .{ .sym = "ConstOmegaTailXor", .want = try blocks.xorIn(rom, 2, 0x7A4B), .from = "02:$7A4B XOR d8" },
        .{ .sym = "ConstOmegaIntroXor", .want = try blocks.xorIn(rom, 2, 0x791D), .from = "02:$791D XOR d8" },
        .{ .sym = "ConstOmegaRange", .want = try blocks.compareIn(rom, 2, 0x78FA), .from = "02:$78FA CP d8, the intro" },
        .{ .sym = "ConstOmegaRange", .want = try blocks.compareIn(rom, 2, 0x795F), .from = "02:$795F CP d8, the seen Omega" },
        .{ .sym = "ConstOmegaRangeBias", .want = try blocks.addIn(rom, 2, 0x78ED), .from = "02:$78ED ADD A,d8, its X" },
        .{ .sym = "ConstOmegaRangeBias", .want = try blocks.addIn(rom, 2, 0x78F3), .from = "02:$78F3 ADD A,d8, Samus's" },
        .{ .sym = "ConstOmegaIntroN", .want = try blocks.compareIn(rom, 2, 0x7916), .from = "02:$7916 CP d8" },
        .{ .sym = "ConstOmegaBackHurt", .want = try blocks.subIn(rom, 2, 0x76A8), .from = "02:$76A8 SUB d8" },
        .{ .sym = "ConstOmegaStunBack", .want = try blocks.loadIn(rom, 2, 0x76AF), .from = "02:$76AF LD A,d8" },
        .{ .sym = "ConstOmegaStunFront", .want = try blocks.loadIn(rom, 2, 0x76B9), .from = "02:$76B9 LD A,d8" },
        .{ .sym = "ConstSfxQueenCry", .want = try blocks.loadIn(rom, 2, 0x76C7), .from = "02:$76C7 LD A,d8" },
        .{ .sym = "ConstOmegaKnock", .want = try blocks.addIn(rom, 2, 0x76D2), .from = "02:$76D2 ADD A,d8, right" },
        .{ .sym = "ConstOmegaKnock", .want = try blocks.subIn(rom, 2, 0x76D9), .from = "02:$76D9 SUB d8, left" },
        .{ .sym = "ConstOmegaKnockLeft", .want = try blocks.compareIn(rom, 2, 0x76DB), .from = "02:$76DB CP d8" },
        .{ .sym = "ConstSfxOmegaKilled", .want = try blocks.loadIn(rom, 2, 0x76F5), .from = "02:$76F5 LD A,d8" },
        .{ .sym = "ConstOmegaScrewIdx", .want = try blocks.loadIn(rom, 2, 0x7737), .from = "02:$7737 LD A,d8" },
        .{ .sym = "ConstOmegaScrewChase", .want = try blocks.loadIn(rom, 2, 0x773C), .from = "02:$773C LD A,d8" },
        .{ .sym = "ConstOmegaVec0", .want = try blocks.loadIn(rom, 2, 0x7740), .from = "02:$7740 LD A,d8, the screw knockback's end" },
        .{ .sym = "ConstOmegaVec0", .want = try blocks.loadIn(rom, 2, 0x7744), .from = "02:$7744 LD A,d8, and the other axis" },
        .{ .sym = "ConstOmegaVec0", .want = try blocks.loadIn(rom, 2, 0x79EE), .from = "02:$79EE LD A,d8, the chase's pick" },
        .{ .sym = "ConstOmegaVec0", .want = try blocks.loadIn(rom, 2, 0x79F2), .from = "02:$79F2 LD A,d8, and the other axis" },
        .{ .sym = "ConstOmegaRest", .want = try blocks.compareIn(rom, 2, 0x779C), .from = "02:$779C CP d8" },
        .{ .sym = "ConstOmegaRest", .want = try blocks.loadIn(rom, 2, 0x78D6), .from = "02:$78D6 LD A,d8, the fireball's deletion" },
        .{ .sym = "ConstOmegaChase", .want = try blocks.compareIn(rom, 2, 0x778A), .from = "02:$778A CP d8" },
        .{ .sym = "ConstOmegaChase", .want = try blocks.loadIn(rom, 2, 0x774C), .from = "02:$774C LD A,d8, the screw knockback's end" },
        .{ .sym = "ConstOmegaChase", .want = try blocks.loadIn(rom, 2, 0x79FF), .from = "02:$79FF LD A,d8, the chase's pick" },
        .{ .sym = "ConstOmegaRise", .want = try blocks.compareIn(rom, 2, 0x778E), .from = "02:$778E CP d8" },
        .{ .sym = "ConstOmegaRise", .want = try blocks.loadIn(rom, 2, 0x77F3), .from = "02:$77F3 LD A,d8" },
        .{ .sym = "ConstOmegaWait", .want = try blocks.compareIn(rom, 2, 0x7792), .from = "02:$7792 CP d8" },
        .{ .sym = "ConstOmegaWait", .want = try blocks.loadIn(rom, 2, 0x7817), .from = "02:$7817 LD A,d8" },
        .{ .sym = "ConstOmegaWaitN", .want = try blocks.compareIn(rom, 2, 0x7757), .from = "02:$7757 CP d8" },
        .{ .sym = "ConstOmegaTailN", .want = try blocks.compareIn(rom, 2, 0x777A), .from = "02:$777A CP d8" },
        .{ .sym = "ConstOmegaMouthN", .want = try blocks.loadBIn(rom, 2, 0x77AA), .from = "02:$77AA LD B,d8" },
        .{ .sym = "ConstOmegaForceIdx", .want = try blocks.compareIn(rom, 2, 0x77C5), .from = "02:$77C5 CP d8" },
        .{ .sym = "ConstOmegaFace", .want = try blocks.compareIn(rom, 2, 0x77E1), .from = "02:$77E1 CP d8" },
        .{ .sym = "ConstOmegaFaceL", .want = try blocks.compareIn(rom, 2, 0x77EB), .from = "02:$77EB CP d8" },
        .{ .sym = "ConstOmegaTop", .want = try blocks.compareIn(rom, 2, 0x7807), .from = "02:$7807 CP d8" },
        .{ .sym = "ConstOmegaFireN", .want = try blocks.compareIn(rom, 2, 0x782C), .from = "02:$782C CP d8" },
        .{ .sym = "ConstOmegaShotOx", .want = try blocks.subIn(rom, 2, 0x7933), .from = "02:$7933 SUB d8" },
        .{ .sym = "ConstOmegaShotOx", .want = try blocks.addIn(rom, 2, 0x793A), .from = "02:$793A ADD A,d8" },
        .{ .sym = "ConstOmegaTimerN", .want = try blocks.compareIn(rom, 2, 0x79AC), .from = "02:$79AC CP d8" },
        .{ .sym = "ConstOmegaHurtBig", .want = try blocks.compareIn(rom, 2, 0x79BB), .from = "02:$79BB CP d8" },
        .{ .sym = "ConstOmegaChase0", .want = try blocks.loadIn(rom, 2, 0x79D4), .from = "02:$79D4 LD A,d8" },
        .{ .sym = "ConstOmegaChase1", .want = try blocks.loadIn(rom, 2, 0x79D8), .from = "02:$79D8 LD A,d8" },
        .{ .sym = "ConstOmegaChase2", .want = try blocks.loadIn(rom, 2, 0x79DC), .from = "02:$79DC LD A,d8" },
        .{ .sym = "ConstOmegaChase3", .want = try blocks.loadIn(rom, 2, 0x79E0), .from = "02:$79E0 LD A,d8" },
        .{ .sym = "ConstOmegaChase4", .want = try blocks.loadIn(rom, 2, 0x79E4), .from = "02:$79E4 LD A,d8" },
        .{ .sym = "ConstSfxOmegaChase", .want = try blocks.loadIn(rom, 2, 0x79FA), .from = "02:$79FA LD A,d8" },
        .{ .sym = "ConstSfxZetaShot", .want = try blocks.loadIn(rom, 2, 0x7841), .from = "02:$7841 LD A,d8, the Omega's spit" },
        .{ .sym = "ConstSeekStep", .want = try blocks.loadBIn(rom, 2, 0x77D0), .from = "02:$77D0 LD B,d8, the Omega's chase" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x765A), .from = "02:$765A LD A,d8, the stunned Omega" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x767C), .from = "02:$767C LD A,d8, the fighting Omega" },
        .{ .sym = "ConstSfxMetroidScrew", .want = try blocks.loadIn(rom, 2, 0x7685), .from = "02:$7685 LD A,d8, the Omega's" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x7657), .from = "02:$7657 CP d8, the stunned Omega" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x7674), .from = "02:$7674 CP d8, the fighting Omega" },
        .{ .sym = "ConstWpnMissile", .want = try blocks.compareIn(rom, 2, 0x7678), .from = "02:$7678 CP d8, the Omega's hurt test" },
        .{ .sym = "ConstEnTouch", .want = try blocks.compareIn(rom, 2, 0x766F), .from = "02:$766F CP d8, the Omega's" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x7902), .from = "02:$7902 LD A,d8, the Omega's intro" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.compareIn(rom, 2, 0x7982), .from = "02:$7982 CP d8, the seen Omega's songPlaying guard" },
        .{ .sym = "ConstSongMetroid", .want = try blocks.loadIn(rom, 2, 0x7985), .from = "02:$7985 LD A,d8, the seen Omega" },
        .{ .sym = "ConstMetStateDying", .want = try blocks.loadIn(rom, 2, 0x76EC), .from = "02:$76EC LD A,d8, the Omega's death" },
        .{ .sym = "ConstSprExpBig", .want = try blocks.loadIn(rom, 2, 0x76F1), .from = "02:$76F1 LD A,d8, the Omega's death" },
        .{ .sym = "ConstSongMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x76FA), .from = "02:$76FA LD A,d8, the Omega's" },
        .{ .sym = "ConstMetFightDied", .want = try blocks.loadIn(rom, 2, 0x76FF), .from = "02:$76FF LD A,d8, the Omega's" },
        .{ .sym = "ConstMetFightDied", .want = try blocks.compareIn(rom, 2, 0x784A), .from = "02:$784A CP d8, the Omega's fireball" },
        .{ .sym = "ConstMetShuffle", .want = try blocks.loadIn(rom, 2, 0x7716), .from = "02:$7716 LD A,d8, the Omega's" },
        .{ .sym = "ConstMetStateFight", .want = try blocks.loadIn(rom, 2, 0x7834), .from = "02:$7834 LD A,d8, the Omega's spit" },
        .{ .sym = "ConstMetStateFight", .want = try blocks.compareIn(rom, 2, 0x78D3), .from = "02:$78D3 CP d8, the Omega's fireball" },
        .{ .sym = "ConstFlagChild", .want = try blocks.compareIn(rom, 2, 0x7636), .from = "02:$7636 CP d8, the Omega's fireball test" },
        .{ .sym = "ConstFlagChild", .want = try blocks.loadIn(rom, 2, 0x7947), .from = "02:$7947 LD A,d8, the Omega's spawn" },
        // 1.0 Step 17: the larvae's and the stinger's.
        .{ .sym = "ConstSprLarva2", .want = try blocks.loadIn(rom, 2, 0x7AC9), .from = "02:$7AC9 LD A,d8, the hurt's end" },
        .{ .sym = "ConstSprLarva2", .want = try blocks.loadIn(rom, 2, 0x7AF4), .from = "02:$7AF4 LD A,d8, the thaw" },
        .{ .sym = "ConstSprLarvaHurt", .want = try blocks.loadIn(rom, 2, 0x7B0A), .from = "02:$7B0A LD A,d8" },
        .{ .sym = "ConstLarvaAnimXor", .want = try blocks.xorIn(rom, 2, 0x7BD5), .from = "02:$7BD5 XOR d8" },
        .{ .sym = "ConstLarvaLatched", .want = try blocks.loadIn(rom, 2, 0x7B75), .from = "02:$7B75 LD A,d8" },
        .{ .sym = "ConstLarvaFlyAway", .want = try blocks.loadIn(rom, 2, 0x7B79), .from = "02:$7B79 LD A,d8" },
        .{ .sym = "ConstLarvaFlyN", .want = try blocks.compareIn(rom, 2, 0x7A76), .from = "02:$7A76 CP d8" },
        .{ .sym = "ConstLarvaFlyStep", .want = try blocks.subIn(rom, 2, 0x7A81), .from = "02:$7A81 SUB d8, up" },
        .{ .sym = "ConstLarvaFlyStep", .want = try blocks.subIn(rom, 2, 0x7A9A), .from = "02:$7A9A SUB d8, left" },
        .{ .sym = "ConstLarvaEdge", .want = try blocks.compareIn(rom, 2, 0x7A83), .from = "02:$7A83 CP d8, the fly-off's top" },
        .{ .sym = "ConstLarvaEdge", .want = try blocks.compareIn(rom, 2, 0x7A9C), .from = "02:$7A9C CP d8, the fly-off's left" },
        .{ .sym = "ConstLarvaEdge", .want = try blocks.compareIn(rom, 2, 0x7CF6), .from = "02:$7CF6 CP d8, metroid_correctPosition's top" },
        .{ .sym = "ConstLarvaEdge", .want = try blocks.compareIn(rom, 2, 0x7D1B), .from = "02:$7D1B CP d8, metroid_correctPosition's left" },
        .{ .sym = "ConstLarvaBombed", .want = try blocks.loadIn(rom, 2, 0x7A7A), .from = "02:$7A7A LD A,d8" },
        .{ .sym = "ConstLarvaBombed", .want = try blocks.compareIn(rom, 2, 0x7B68), .from = "02:$7B68 CP d8" },
        .{ .sym = "ConstLarvaTouched", .want = try blocks.compareIn(rom, 2, 0x7B6C), .from = "02:$7B6C CP d8" },
        .{ .sym = "ConstLarvaTouched", .want = try blocks.loadIn(rom, 2, 0x7B70), .from = "02:$7B70 LD A,d8" },
        .{ .sym = "ConstLarvaVec0", .want = try blocks.loadIn(rom, 2, 0x7AB9), .from = "02:$7AB9 LD A,d8, the restart" },
        .{ .sym = "ConstLarvaVec0", .want = try blocks.loadIn(rom, 2, 0x7AEE), .from = "02:$7AEE LD A,d8, the thaw" },
        .{ .sym = "ConstLarvaVec0", .want = try blocks.loadIn(rom, 2, 0x7BB7), .from = "02:$7BB7 LD A,d8, the knockback's end" },
        .{ .sym = "ConstLarvaVec0", .want = try blocks.compareIn(rom, 2, 0x7CDF), .from = "02:$7CDF CP d8, metroid_correctPosition's Y half" },
        .{ .sym = "ConstLarvaVec0", .want = try blocks.compareIn(rom, 2, 0x7D06), .from = "02:$7D06 CP d8, and its X half" },
        .{ .sym = "ConstLarvaHealth", .want = try blocks.loadIn(rom, 2, 0x7AF8), .from = "02:$7AF8 LD A,d8" },
        .{ .sym = "ConstLarvaHurtN", .want = try blocks.loadIn(rom, 2, 0x7B05), .from = "02:$7B05 LD A,d8" },
        .{ .sym = "ConstLarvaStunIce", .want = try blocks.loadIn(rom, 2, 0x7B97), .from = "02:$7B97 LD A,d8" },
        .{ .sym = "ConstLarvaIce", .want = try blocks.loadIn(rom, 2, 0x7B9B), .from = "02:$7B9B LD A,d8" },
        .{ .sym = "ConstLarvaExplode", .want = try blocks.loadIn(rom, 2, 0x7B21), .from = "02:$7B21 LD A,d8" },
        .{ .sym = "ConstLarvaSeekStep", .want = try blocks.loadBIn(rom, 2, 0x7BC0), .from = "02:$7BC0 LD B,d8" },
        .{ .sym = "ConstSfxMetroidHurt", .want = try blocks.loadIn(rom, 2, 0x7B0E), .from = "02:$7B0E LD A,d8, the larva's" },
        .{ .sym = "ConstSfxMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x7B25), .from = "02:$7B25 LD A,d8, the larva's" },
        .{ .sym = "ConstSfxMetroidScrew", .want = try blocks.loadIn(rom, 2, 0x7B8C), .from = "02:$7B8C LD A,d8, the larva's screw and bomb" },
        .{ .sym = "ConstSfxMetroidScrew", .want = try blocks.loadIn(rom, 2, 0x7B92), .from = "02:$7B92 LD A,d8, the larva's freeze" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x7AE8), .from = "02:$7AE8 LD A,d8, the frozen larva" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x7B5E), .from = "02:$7B5E LD A,d8, the free larva" },
        .{ .sym = "ConstMetShuffle", .want = try blocks.loadIn(rom, 2, 0x7B3A), .from = "02:$7B3A LD A,d8, the larva's" },
        .{ .sym = "ConstWpnBomb", .want = try blocks.compareIn(rom, 2, 0x7A69), .from = "02:$7A69 CP d8, the latched larva" },
        .{ .sym = "ConstWpnBomb", .want = try blocks.compareIn(rom, 2, 0x7B57), .from = "02:$7B57 CP d8, the free larva" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x7B53), .from = "02:$7B53 CP d8, the larva's" },
        .{ .sym = "ConstWpnMissile", .want = try blocks.compareIn(rom, 2, 0x7AE0), .from = "02:$7AE0 CP d8, the frozen larva" },
        .{ .sym = "ConstEnTouch", .want = try blocks.compareIn(rom, 2, 0x7ADD), .from = "02:$7ADD CP d8, the frozen larva" },
        .{ .sym = "ConstEnTouch", .want = try blocks.compareIn(rom, 2, 0x7B4E), .from = "02:$7B4E CP d8, the free larva" },
        .{ .sym = "ConstStingerEnd", .want = try blocks.compareIn(rom, 2, 0x6B88), .from = "02:$6B88 CP d8" },
        .{ .sym = "ConstStingerLarvae", .want = try blocks.addIn(rom, 2, 0x6B92), .from = "02:$6B92 ADD A,d8" },
        .{ .sym = "ConstStingerShuffle", .want = try blocks.loadIn(rom, 2, 0x6B96), .from = "02:$6B96 LD A,d8" },
        .{ .sym = "ConstSongHive", .want = try blocks.loadIn(rom, 2, 0x6B9B), .from = "02:$6B9B LD A,d8" },
        // 1.0 Step 2a: `tryPausing` and `gameMode_Paused`.
        .{ .sym = "ConstQueenRoom", .want = try blocks.compareIn(rom, 0, 0x2C81), .from = "00:$2C81 CP d8, tryPausing's Queen room" },
        .{ .sym = "ConstIconMask", .want = try blocks.andIn(rom, 0, 0x2CC9), .from = "00:$2CC9 AND d8" },
        .{ .sym = "ConstIconMask", .want = try blocks.compareIn(rom, 0, 0x2CCB), .from = "00:$2CCB CP d8" },
        .{ .sym = "ConstGbOamMax", .want = try blocks.compareIn(rom, 0, 0x2CD3), .from = "00:$2CD3 CP d8, the search's end" },
        .{ .sym = "ConstLBlank", .want = try blocks.loadIn(rom, 0, 0x2CDC), .from = "00:$2CDC LD A,d8" },
        .{ .sym = "ConstLTile", .want = try blocks.loadIn(rom, 0, 0x2CE0), .from = "00:$2CE0 LD A,d8" },
        .{ .sym = "ConstPauseDark", .want = try blocks.loadBIn(rom, 0, 0x2CED), .from = "00:$2CED LD B,d8, the flash's dark half" },
        .{ .sym = "ConstMetOrigin", .want = try blocks.addIn(rom, 2, 0x6CBF), .from = "02:$6CBF ADD A,d8, the lunge facing test" },
        .{ .sym = "ConstAlphaStunN", .want = try blocks.loadIn(rom, 2, 0x6CFA), .from = "02:$6CFA LD A,d8" },
        .{ .sym = "ConstSfxMetroidHurt", .want = try blocks.loadIn(rom, 2, 0x6CFF), .from = "02:$6CFF LD A,d8" },
        .{ .sym = "ConstSfxMetroidScrew", .want = try blocks.loadIn(rom, 2, 0x6CEC), .from = "02:$6CEC LD A,d8" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x6BCB), .from = "02:$6BCB LD A,d8, the stunned Alpha" },
        .{ .sym = "ConstSfxBeamDink", .want = try blocks.loadIn(rom, 2, 0x6C8D), .from = "02:$6C8D LD A,d8, the fighting Alpha" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x6BC8), .from = "02:$6BC8 CP d8" },
        .{ .sym = "ConstWpnScrew", .want = try blocks.compareIn(rom, 2, 0x6C85), .from = "02:$6C85 CP d8" },
        .{ .sym = "ConstWpnMissile", .want = try blocks.compareIn(rom, 2, 0x6C89), .from = "02:$6C89 CP d8, the Alpha's hurt test" },
        .{ .sym = "ConstEnTouch", .want = try blocks.compareIn(rom, 2, 0x6C80), .from = "02:$6C80 CP d8, the Alpha's" },
        .{ .sym = "ConstAlphaKnock", .want = try blocks.subIn(rom, 2, 0x6D1B), .from = "02:$6D1B SUB d8, up" },
        .{ .sym = "ConstAlphaKnock", .want = try blocks.addIn(rom, 2, 0x6D2B), .from = "02:$6D2B ADD A,d8, down" },
        .{ .sym = "ConstAlphaKnock", .want = try blocks.addIn(rom, 2, 0x6D40), .from = "02:$6D40 ADD A,d8, right" },
        .{ .sym = "ConstAlphaKnock", .want = try blocks.subIn(rom, 2, 0x6D48), .from = "02:$6D48 SUB d8, left" },
        .{ .sym = "ConstAlphaKnockTop", .want = try blocks.compareIn(rom, 2, 0x6D1D), .from = "02:$6D1D CP d8" },
        .{ .sym = "ConstAlphaKnockLeft", .want = try blocks.compareIn(rom, 2, 0x6D4A), .from = "02:$6D4A CP d8" },
        .{ .sym = "ConstScrewKnockN", .want = try blocks.compareIn(rom, 2, 0x6E84), .from = "02:$6E84 CP d8" },
        .{ .sym = "ConstScrewKnock", .want = try blocks.subIn(rom, 2, 0x6E9F), .from = "02:$6E9F SUB d8, up" },
        .{ .sym = "ConstScrewKnock", .want = try blocks.subIn(rom, 2, 0x6EB5), .from = "02:$6EB5 SUB d8, left" },
        .{ .sym = "ConstScrewKnock", .want = try blocks.addIn(rom, 2, 0x6ECB), .from = "02:$6ECB ADD A,d8, right" },
        .{ .sym = "ConstScrewKnock", .want = try blocks.addIn(rom, 2, 0x6EDE), .from = "02:$6EDE ADD A,d8, down" },
        .{ .sym = "ConstKnockTop", .want = try blocks.compareIn(rom, 2, 0x6EA1), .from = "02:$6EA1 CP d8, the screw knockback up" },
        .{ .sym = "ConstKnockTop", .want = try blocks.compareIn(rom, 2, 0x6EB7), .from = "02:$6EB7 CP d8, the screw knockback left" },
        .{ .sym = "ConstKnockTop", .want = try blocks.compareIn(rom, 2, 0x6F56), .from = "02:$6F56 CP d8, the missile knockback's moveBack" },
        .{ .sym = "ConstMissKnock", .want = try blocks.subIn(rom, 2, 0x6F54), .from = "02:$6F54 SUB d8" },
        .{ .sym = "ConstMissKnock", .want = try blocks.addIn(rom, 2, 0x6F5C), .from = "02:$6F5C ADD A,d8" },
        .{ .sym = "ConstMetOrigin", .want = try blocks.addIn(rom, 1, 0x70C5), .from = "01:$70C5 ADD A,d8, Y" },
        .{ .sym = "ConstMetOrigin", .want = try blocks.addIn(rom, 1, 0x70E2), .from = "01:$70E2 ADD A,d8, X" },
        .{ .sym = "ConstMetSlopeMul", .want = try blocks.loadBIn(rom, 1, 0x7170), .from = "01:$7170 LD B,d8" },
        .{ .sym = "ConstSlopeShallow", .want = try blocks.compareIn(rom, 1, 0x7192), .from = "01:$7192 CP d8" },
        .{ .sym = "ConstSlopeDiag", .want = try blocks.compareIn(rom, 1, 0x7196), .from = "01:$7196 CP d8" },
        .{ .sym = "ConstSlopeSteep", .want = try blocks.compareIn(rom, 1, 0x719A), .from = "01:$719A CP d8" },
        .{ .sym = "ConstSlopeHi", .want = try blocks.compareIn(rom, 1, 0x71A0), .from = "01:$71A0 CP d8" },
        .{ .sym = "ConstSlopeHiLo", .want = try blocks.compareIn(rom, 1, 0x71AB), .from = "01:$71AB CP d8" },
        .{ .sym = "ConstEnFarWide", .want = try blocks.subIn(rom, 2, 0x473D), .from = "02:$473D SUB d8, right.farWide's Y" },
        .{ .sym = "ConstEnFarWide", .want = try blocks.addIn(rom, 2, 0x4744), .from = "02:$4744 ADD A,d8, right.farWide's X" },
        .{ .sym = "ConstEnFarWide", .want = try blocks.subIn(rom, 2, 0x491D), .from = "02:$491D SUB d8, left.farWide's X" },
        .{ .sym = "ConstEnFarWide", .want = try blocks.addIn(rom, 2, 0x4B1E), .from = "02:$4B1E ADD A,d8, down.farWide's Y" },
        .{ .sym = "ConstEnFarWide", .want = try blocks.subIn(rom, 2, 0x4D0B), .from = "02:$4D0B SUB d8, up.farWide's Y" },
        .{ .sym = "ConstEnBgRight", .want = try blocks.loadIn(rom, 2, 0x4736), .from = "02:$4736 LD A,d8, right.farWide" },
        .{ .sym = "ConstEnBgLeft", .want = try blocks.loadIn(rom, 2, 0x490F), .from = "02:$490F LD A,d8, left.farWide" },
        .{ .sym = "ConstEnBgDown", .want = try blocks.loadIn(rom, 2, 0x4B17), .from = "02:$4B17 LD A,d8, down.farWide" },
        .{ .sym = "ConstEnBgUp", .want = try blocks.loadIn(rom, 2, 0x4D04), .from = "02:$4D04 LD A,d8, up.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x4754), .from = "02:$4754 ADD A,d8, right.farWide" },
        .{ .sym = "ConstEnWideStepMid", .want = try blocks.addIn(rom, 2, 0x4764), .from = "02:$4764 ADD A,d8, right.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x4774), .from = "02:$4774 ADD A,d8, right.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x492D), .from = "02:$492D ADD A,d8, left.farWide" },
        .{ .sym = "ConstEnWideStepMid", .want = try blocks.addIn(rom, 2, 0x493D), .from = "02:$493D ADD A,d8, left.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x494D), .from = "02:$494D ADD A,d8, left.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x4B35), .from = "02:$4B35 ADD A,d8, down.farWide" },
        .{ .sym = "ConstEnWideStepMid", .want = try blocks.addIn(rom, 2, 0x4B45), .from = "02:$4B45 ADD A,d8, down.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x4B55), .from = "02:$4B55 ADD A,d8, down.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x4D22), .from = "02:$4D22 ADD A,d8, up.farWide" },
        .{ .sym = "ConstEnWideStepMid", .want = try blocks.addIn(rom, 2, 0x4D32), .from = "02:$4D32 ADD A,d8, up.farWide" },
        .{ .sym = "ConstEnWideStepOut", .want = try blocks.addIn(rom, 2, 0x4D42), .from = "02:$4D42 ADD A,d8, up.farWide" },
        .{ .sym = "ConstCrawlSprVert", .want = try blocks.addIn(rom, 2, 0x58B4), .from = "02:$58B4 ADD A,d8" },
        .{ .sym = "ConstCrawlAttrH", .want = try blocks.loadIn(rom, 2, 0x58A3), .from = "02:$58A3 LD A,d8" },
        .{ .sym = "ConstCrawlAttrV", .want = try blocks.loadIn(rom, 2, 0x58C8), .from = "02:$58C8 LD A,d8" },
        .{ .sym = "ConstHopArcN", .want = try blocks.compareIn(rom, 2, 0x61E9), .from = "02:$61E9 CP d8" },
        .{ .sym = "ConstHopFallTop", .want = try blocks.loadIn(rom, 2, 0x6239), .from = "02:$6239 LD A,d8" },
        .{ .sym = "ConstHopFrameAt", .want = try blocks.compareIn(rom, 2, 0x6218), .from = "02:$6218 CP d8" },
        .{ .sym = "ConstHopTurnN", .want = try blocks.compareIn(rom, 2, 0x624C), .from = "02:$624C CP d8" },
        .{ .sym = "ConstHopFaceX", .want = try blocks.compareIn(rom, 2, 0x6289), .from = "02:$6289 CP d8" },
        .{ .sym = "ConstSprAutoad2", .want = try blocks.compareIn(rom, 2, 0x6220), .from = "02:$6220 CP d8" },
        .{ .sym = "ConstSfxAutoadJump", .want = try blocks.loadIn(rom, 2, 0x6223), .from = "02:$6223 LD A,d8" },
        // Step 13d: the Alpha's death, the explosion every slot is handed while
        // it plays, and the restore at the top of the enemy handler.
        .{ .sym = "ConstMetStateDying", .want = try blocks.loadIn(rom, 2, 0x6D66), .from = "02:$6D66 LD A,d8" },
        .{ .sym = "ConstMetStateDying", .want = try blocks.compareIn(rom, 2, 0x5643), .from = "02:$5643 CP d8, enemy_commonAI" },
        .{ .sym = "ConstSprExpBig", .want = try blocks.loadIn(rom, 2, 0x6D6B), .from = "02:$6D6B LD A,d8, the death" },
        .{ .sym = "ConstSprExpBig", .want = try blocks.compareIn(rom, 2, 0x573A), .from = "02:$573A CP d8, the explosion's test" },
        .{ .sym = "ConstSprExpBig", .want = try blocks.addIn(rom, 2, 0x5758), .from = "02:$5758 ADD A,d8, the explosion's frame" },
        .{ .sym = "ConstSfxMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x6D6F), .from = "02:$6D6F LD A,d8" },
        .{ .sym = "ConstSongMetroidKilled", .want = try blocks.loadIn(rom, 2, 0x6D74), .from = "02:$6D74 LD A,d8" },
        .{ .sym = "ConstMetFightDied", .want = try blocks.loadIn(rom, 2, 0x6D79), .from = "02:$6D79 LD A,d8" },
        .{ .sym = "ConstMetFightDied", .want = try blocks.compareIn(rom, 2, 0x402F), .from = "02:$402F CP d8, enemyHandler" },
        .{ .sym = "ConstMetShuffle", .want = try blocks.loadIn(rom, 2, 0x6D90), .from = "02:$6D90 LD A,d8" },
        .{ .sym = "ConstMetExpEnd", .want = try blocks.compareIn(rom, 2, 0x573F), .from = "02:$573F CP d8" },
        .{ .sym = "ConstMetExpN", .want = try blocks.compareIn(rom, 2, 0x5754), .from = "02:$5754 CP d8" },
        .{ .sym = "ConstMetExpStep", .want = try blocks.subIn(rom, 2, 0x5789), .from = "02:$5789 SUB d8, left" },
        .{ .sym = "ConstMetExpStep", .want = try blocks.subIn(rom, 2, 0x5794), .from = "02:$5794 SUB d8, up" },
        .{ .sym = "ConstMetExpStep", .want = try blocks.addIn(rom, 2, 0x579B), .from = "02:$579B ADD A,d8, right" },
        .{ .sym = "ConstMetExpStep", .want = try blocks.addIn(rom, 2, 0x57A6), .from = "02:$57A6 ADD A,d8, down" },
        .{ .sym = "ConstMetEdgeWrap", .want = try blocks.compareIn(rom, 2, 0x57B7), .from = "02:$57B7 CP d8, Y" },
        .{ .sym = "ConstMetEdgeWrap", .want = try blocks.compareIn(rom, 2, 0x57C5), .from = "02:$57C5 CP d8, X" },
        .{ .sym = "ConstMetEdgeFar", .want = try blocks.compareIn(rom, 2, 0x57BB), .from = "02:$57BB CP d8, Y" },
        .{ .sym = "ConstMetEdgeFar", .want = try blocks.compareIn(rom, 2, 0x57C9), .from = "02:$57C9 CP d8, X" },
        .{ .sym = "ConstMetEdgeNear", .want = try blocks.compareIn(rom, 2, 0x57BF), .from = "02:$57BF CP d8, Y" },
        .{ .sym = "ConstMetEdgeNear", .want = try blocks.compareIn(rom, 2, 0x57CD), .from = "02:$57CD CP d8, X" },
        .{ .sym = "ConstMetEdgeLo", .want = try blocks.loadHlIn(rom, 2, 0x57D0), .from = "02:$57D0 LD (HL),d8, left" },
        .{ .sym = "ConstMetEdgeLo", .want = try blocks.loadHlIn(rom, 2, 0x57D7), .from = "02:$57D7 LD (HL),d8, top" },
        .{ .sym = "ConstMetEdgeHi", .want = try blocks.loadHlIn(rom, 2, 0x57D3), .from = "02:$57D3 LD (HL),d8, bottom" },
        .{ .sym = "ConstMetEdgeHi", .want = try blocks.loadHlIn(rom, 2, 0x57DB), .from = "02:$57DB LD (HL),d8, right" },
        .{ .sym = "ConstPostDeathN", .want = try blocks.compareIn(rom, 2, 0x403D), .from = "02:$403D CP d8" },
        .{ .sym = "ConstSongRestore", .want = try blocks.addIn(rom, 2, 0x4054), .from = "02:$4054 ADD A,d8" },
        .{ .sym = "ConstFlagChild", .want = try blocks.compareIn(rom, 2, 0x5734), .from = "02:$5734 CP d8, the explosion's projectile test" },
    };
    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print("{s}: engine has ${X:0>2}, the cartridge's {s} says ${X:0>2}\n", .{ c.sym, got, c.from, c.want });
            bad += 1;
        }
    }
    // Each edge's `.exit` is `LD HL,$C402` then `RES n,(HL)`, and the engine's
    // mask is the complement of that bit. The `RES` sites are found by walking
    // forward from each probe's preset, which is what makes the bit the ROM's.
    const Exit = struct { sym: []const u8, res: u16 };
    for ([_]Exit{
        .{ .sym = "ConstEnBgDownClr", .res = 0x4A25 },
        .{ .sym = "ConstEnBgRightClr", .res = 0x47B1 },
        .{ .sym = "ConstEnBgLeftClr", .res = 0x498A },
        .{ .sym = "ConstEnBgUpClr", .res = 0x4DAE },
    }) |e| {
        const at = blocks.offsetIn(2, e.res);
        try testing.expectEqual(@as(u8, 0xCB), rom[at]);
        const op = rom[at + 1];
        // `RES n,(HL)` is `CB 86+8n`.
        try testing.expectEqual(@as(u8, 0x86), op & 0xC7);
        const bit: u3 = @truncate(op >> 3);
        if (@as(u8, @truncate(inject.symbol(e.sym).?)) != ~(@as(u8, 1) << bit)) {
            std.debug.print("{s}: not the complement of bit {d} at 02:${X:0>4}\n", .{ e.sym, bit, e.res });
            bad += 1;
        }
    }

    // `LD (HL),d8` is `36 nn`, which no reader above covers.
    const Store = struct { sym: []const u8, site: u16 };
    for ([_]Store{
        .{ .sym = "ConstGulSpr1", .site = 0x5E08 },
        .{ .sym = "ConstSprLeech1", .site = 0x5E81 },
        .{ .sym = "ConstSprLeech2", .site = 0x5E32 },
        .{ .sym = "ConstSprLeech3", .site = 0x5E60 },
        .{ .sym = "ConstSprOctroll3", .site = 0x5E63 },
        .{ .sym = "ConstSprYumee3", .site = 0x6057 },
    }) |st| {
        const o = blocks.offsetIn(2, st.site);
        try testing.expectEqual(@as(u8, 0x36), rom[o]);
        if (@as(u8, @truncate(inject.symbol(st.sym).?)) != rom[o + 1]) {
            std.debug.print("{s}: not the operand of 02:${X:0>4} LD (HL),d8\n", .{ st.sym, st.site });
            bad += 1;
        }
    }
    // `LD C,d8` is `0E nn`.
    try testing.expectEqual(@as(u8, 0x0E), rom[blocks.offsetIn(2, 0x6017)]);
    if (@as(u8, @truncate(inject.symbol("ConstPipeLeft").?)) != rom[blocks.offsetIn(2, 0x6018)]) bad += 1;
    // `LD (HL),$4A` and the door's two explosion bounds, which no reader above
    // takes: the blast is the screw attack's own progression, so the port
    // reuses `!SPR_EXP_BIG` and the test says that is the ROM's number.
    try testing.expectEqualSlices(u8, &.{ 0x36, 0x4A }, rom[blocks.offsetIn(2, 0x62BC)..][0..2]);
    if (try blocks.loadIn(rom, 2, 0x6A49) != @as(u8, @truncate(inject.symbol("ConstSprExpBig").?))) bad += 1;
    if (try blocks.compareIn(rom, 2, 0x6A65) != @as(u8, @truncate(inject.symbol("ConstSprExpBig").?)) + 5) bad += 1;
    {
        const o = blocks.offsetIn(2, 0x6316);
        try testing.expectEqual(@as(u8, 0x11), rom[o]);
        const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
        const want = rom[blocks.offsetIn(2, addr)..][0..10];
        const at = inject.symbolOffset("WallfireShotHeader") orelse return error.MissingSymbol;
        if (!std.mem.eql(u8, inject.image[at..][0..10], want)) {
            std.debug.print("WallfireShotHeader is not the ten bytes at 02:${X:0>4}\n", .{addr});
            bad += 1;
        }
    }
    // Step 13c. `alpha_getSpeedVector` jumps through sixteen words at 01:$71DB,
    // and the engine reads the operand out of each arm rather than keeping a
    // table: so the words have to be the blob's own address plus four per arm,
    // and every arm `LD BC,d16 / RET`, or the offset it reads is not an operand.
    {
        const e = offsets.find("alpha_speedVectors").?;
        const jt = blocks.offsetIn(1, 0x71DB);
        try testing.expectEqualSlices(u8, &.{ 0x21, 0xDB, 0x71 }, rom[blocks.offsetIn(1, 0x71CB)..][0..3]);
        for (0..16) |i| {
            const w = @as(u16, rom[jt + 2 * i]) | (@as(u16, rom[jt + 2 * i + 1]) << 8);
            if (w != e.gb_addr + 4 * i) {
                std.debug.print("alpha_getSpeedVector arm {d} is at 01:${X:0>4}, not 01:${X:0>4}\n", .{ i, w, e.gb_addr + 4 * i });
                bad += 1;
            }
            const o = blocks.offsetIn(1, w);
            if (rom[o] != 0x01 or rom[o + 3] != 0xC9) {
                std.debug.print("alpha_getSpeedVector arm {d} at 01:${X:0>4} is not LD BC,d16 / RET\n", .{ i, w });
                bad += 1;
            }
        }
        if (e.size != 16 * 4) bad += 1;
        // And the angle table is the one its reader loads.
        try testing.expectEqualSlices(u8, &.{ 0x21, 0x58, 0x71 }, rom[blocks.offsetIn(1, 0x7131)..][0..3]);
        if (offsets.find("alpha_angleTable").?.gb_addr != 0x7158) bad += 1;
    }
    // 1.0 Step 14: the Gamma's twenty-four arms, the same way, through the
    // jump table at 01:$7329; and its angle table is the one 01:$7275 loads.
    {
        const e = offsets.find("gamma_speedVectors").?;
        const jt = blocks.offsetIn(1, 0x7329);
        try testing.expectEqualSlices(u8, &.{ 0x21, 0x29, 0x73 }, rom[blocks.offsetIn(1, 0x7319)..][0..3]);
        for (0..24) |i| {
            const w = @as(u16, rom[jt + 2 * i]) | (@as(u16, rom[jt + 2 * i + 1]) << 8);
            if (w != e.gb_addr + 4 * i) {
                std.debug.print("gamma_getSpeedVector arm {d} is at 01:${X:0>4}, not 01:${X:0>4}\n", .{ i, w, e.gb_addr + 4 * i });
                bad += 1;
            }
            const o = blocks.offsetIn(1, w);
            if (rom[o] != 0x01 or rom[o + 3] != 0xC9) {
                std.debug.print("gamma_getSpeedVector arm {d} at 01:${X:0>4} is not LD BC,d16 / RET\n", .{ i, w });
                bad += 1;
            }
        }
        if (e.size != 24 * 4) bad += 1;
        try testing.expectEqualSlices(u8, &.{ 0x21, 0x9C, 0x72 }, rom[blocks.offsetIn(1, 0x7275)..][0..3]);
        if (offsets.find("gamma_angleTable").?.gb_addr != 0x729C) bad += 1;
    }
    // 1.0 Step 15: `enemy_seekSamus`'s table is the one both its loads name,
    // and the Zeta's D and E are the `LD DE,d16` before its call, and
    // `metroid_keepOnscreen`'s B and C its `LD BC,d16`.
    {
        for ([_]u16{ 0x6B97, 0x6BA6 }) |site| {
            try testing.expectEqualSlices(u8, &.{ 0x21, 0xB1, 0x6B }, rom[blocks.offsetIn(3, site)..][0..3]);
        }
        if (offsets.find("seekSamus_speedTable").?.gb_addr != 0x6BB1) bad += 1;
        const o = blocks.offsetIn(2, 0x7379);
        try testing.expectEqual(@as(u8, 0x11), rom[o]); // LD DE,d16
        // 1.0 Step 16: the Omega's chase passes the same D and E (02:$77D2).
        try testing.expectEqualSlices(u8, rom[o..][0..3], rom[blocks.offsetIn(2, 0x77D2)..][0..3]);
        // 1.0 Step 17: the larva's seek, its own D and E (02:$7BC2).
        const lo = blocks.offsetIn(2, 0x7BC2);
        try testing.expectEqual(@as(u8, 0x11), rom[lo]); // LD DE,d16
        const kb = try blocks.loadBcIn(rom, 2, 0x7DC6);
        for ([_]struct { sym: []const u8, want: u8 }{
            .{ .sym = "ConstSeekMax", .want = rom[o + 2] },
            .{ .sym = "ConstSeekMin", .want = rom[o + 1] },
            .{ .sym = "ConstLarvaSeekMax", .want = rom[lo + 2] },
            .{ .sym = "ConstLarvaSeekMin", .want = rom[lo + 1] },
            .{ .sym = "ConstKeepLo", .want = kb.b },
            .{ .sym = "ConstKeepHi", .want = kb.c },
        }) |k| {
            const v = (inject.symbol(k.sym) orelse return error.MissingSymbol) & 0xFF;
            if (v != k.want) {
                std.debug.print("{s} is ${X:0>2}, the ROM's is ${X:0>2}\n", .{ k.sym, v, k.want });
                bad += 1;
            }
        }
    }
    // 1.0 Step 19b: the Queen's four tables are the ones their loads name,
    // every pointer the neck and feet tables keep lands inside its blob, and
    // the engine's bases, which turn those pointers into offsets, are the
    // loads' operands.
    {
        const Load = struct { at: u16, op: u8, name: []const u8 };
        for ([_]Load{
            .{ .at = 0x7477, .op = 0x21, .name = "queen_neckPatterns" },
            .{ .at = 0x708F, .op = 0x21, .name = "queen_feet" },
            .{ .at = 0x6DBC, .op = 0x21, .name = "queen_stateList" },
            .{ .at = 0x785F, .op = 0x21, .name = "queen_stateList" },
            .{ .at = 0x7C07, .op = 0x11, .name = "queen_walkSpeeds" },
            .{ .at = 0x799C, .op = 0x11, .name = "queen_bentNeckSprite" },
        }) |l| {
            const o = blocks.offsetIn(3, l.at);
            const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
            if (rom[o] != l.op or addr != offsets.find(l.name).?.gb_addr) {
                std.debug.print("03:${X:0>4} does not load {s}\n", .{ l.at, l.name });
                bad += 1;
            }
        }
        // The feet's other three loads, which the engine spells as offsets.
        for ([_]struct { at: u16, want: u16 }{
            .{ .at = 0x7085, .want = 0x70CA },
            .{ .at = 0x7088, .want = 0x7134 },
            .{ .at = 0x7092, .want = 0x7124 },
        }) |l| {
            const o = blocks.offsetIn(3, l.at);
            if ((@as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8)) != l.want) bad += 1;
        }
        for ([_]struct { name: []const u8, n: usize }{
            .{ .name = "queen_neckPatterns", .n = 7 },
            .{ .name = "queen_feet", .n = 6 },
        }) |t| {
            const e = offsets.find(t.name).?;
            const o = blocks.offsetIn(3, e.gb_addr);
            for (0..t.n) |i| {
                const p = @as(u16, rom[o + 2 * i]) | (@as(u16, rom[o + 2 * i + 1]) << 8);
                if (p < e.gb_addr + 2 * t.n or p >= e.gb_addr + e.size) {
                    std.debug.print("{s} pointer {d}, ${X:0>4}, is outside it\n", .{ t.name, i, p });
                    bad += 1;
                }
            }
        }
        for ([_]struct { sym: []const u8, name: []const u8 }{
            .{ .sym = "ConstQueenNeckGb", .name = "queen_neckPatterns" },
            .{ .sym = "ConstQueenFeetGb", .name = "queen_feet" },
        }) |k| {
            const v = (inject.symbol(k.sym) orelse return error.MissingSymbol) & 0xFFFF;
            if (v != offsets.find(k.name).?.gb_addr) bad += 1;
        }
    }
    // The pipe bug's header is eleven bytes the engine carries, not a blob --
    // under the file policy's run length -- so it is compared whole, and its
    // address is the `LD DE,d16` that reads it.
    {
        const o = blocks.offsetIn(2, 0x5FA9);
        try testing.expectEqual(@as(u8, 0x11), rom[o]);
        const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
        const want = rom[blocks.offsetIn(2, addr)..][0..11];
        const at = inject.symbolOffset("PipeBugHeader") orelse return error.MissingSymbol;
        if (!std.mem.eql(u8, inject.image[at..][0..11], want)) {
            std.debug.print("PipeBugHeader is not the eleven bytes at 02:${X:0>4}\n", .{addr});
            bad += 1;
        }
    }
    // 1.0 Step 11: the skreek's and the drivel's spit headers, carried whole,
    // each at the `LD DE,d16` that reads it.
    for ([_]struct { sym: []const u8, site: u16, len: usize }{
        .{ .sym = "SkreekSpitHeader", .site = 0x5A66, .len = 10 },
        .{ .sym = "DrivelSpitHeader", .site = 0x5B5E, .len = 13 },
        // 1.0 Step 12's: the autrack's laser, the autom's flame, the gunzoo's
        // three shots and the blob thrower's four blobs.
        .{ .sym = "AutrackLaserHeader", .site = 0x6195, .len = 10 },
        .{ .sym = "AutomFlameHeader", .site = 0x658B, .len = 13 },
        .{ .sym = "GunzooUpperHeader", .site = 0x63F5, .len = 13 },
        .{ .sym = "GunzooLowerHeader", .site = 0x6421, .len = 13 },
        .{ .sym = "GunzooDiagHeader", .site = 0x6497, .len = 13 },
        .{ .sym = "BlobHeaderA", .site = 0x4F6E, .len = 13 },
        .{ .sym = "BlobHeaderB", .site = 0x4F74, .len = 13 },
        .{ .sym = "BlobHeaderC", .site = 0x4F7A, .len = 13 },
        .{ .sym = "BlobHeaderD", .site = 0x4F80, .len = 13 },
        // 1.0 Step 13's: Arachnus's fireball.
        .{ .sym = "ArachnusFireHeader", .site = 0x5239, .len = 13 },
        // 1.0 Step 14's: the Gamma's bolt, seven header bytes and three.
        .{ .sym = "GammaBoltHeader", .site = 0x71BA, .len = 10 },
        // 1.0 Step 15's: the Zeta's husk, ten header bytes and three, and its
        // fireball, seven and three.
        .{ .sym = "ZetaHuskHeader", .site = 0x7568, .len = 13 },
        .{ .sym = "ZetaShotHeader", .site = 0x75D1, .len = 10 },
        // 1.0 Step 16's: the Omega's fireball, seven and three.
        .{ .sym = "OmegaShotHeader", .site = 0x7944, .len = 10 },
    }) |h| {
        const o = blocks.offsetIn(2, h.site);
        try testing.expectEqual(@as(u8, 0x11), rom[o]);
        const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
        const want = rom[blocks.offsetIn(2, addr)..][0..h.len];
        const at = inject.symbolOffset(h.sym) orelse return error.MissingSymbol;
        if (!std.mem.eql(u8, inject.image[at..][0..h.len], want)) {
            std.debug.print("{s} is not the {d} bytes at 02:${X:0>4}\n", .{ h.sym, h.len, addr });
            bad += 1;
        }
    }
    // The two arc tables are physics blobs, not engine bytes, and
    // `snes_convert`'s physics test is what grades them against the ROM. What
    // is asserted here is that each is the table its reader's `LD HL,d16` names.
    const Table = struct { entry: []const u8, site: u16 };
    for ([_]Table{
        .{ .entry = "enemy_hopperArcY", .site = 0x61FB },
        .{ .entry = "enemy_hopperArcX", .site = 0x6203 },
        .{ .entry = "enemy_gulluggYSpeeds", .site = 0x5CE9 },
        .{ .entry = "enemy_gulluggXSpeeds", .site = 0x5CFE },
        .{ .entry = "enemy_chuteLeechXSpeeds", .site = 0x5E6C },
        .{ .entry = "enemy_chuteLeechYSpeeds", .site = 0x5EBA },
        .{ .entry = "enemy_accelForwards", .site = 0x6A8B },
        .{ .entry = "enemy_accelBackwards", .site = 0x6ABE },
        .{ .entry = "enemy_skreekJumpSpeeds", .site = 0x5A18 },
        .{ .entry = "enemy_skreekJumpSpeeds", .site = 0x5A34 },
        .{ .entry = "enemy_drivelYSpeeds", .site = 0x5AF4 },
        .{ .entry = "enemy_drivelXSpeeds", .site = 0x5B14 },
        .{ .entry = "enemy_sineConcaveSpeeds", .site = 0x67AD },
        .{ .entry = "enemy_sineConcaveSpeeds", .site = 0x67B7 },
        .{ .entry = "enemy_sineConcaveSpeeds", .site = 0x67F4 },
        .{ .entry = "enemy_sineConcaveSpeeds", .site = 0x67FE },
        .{ .entry = "enemy_sineConcaveSpeeds", .site = 0x681E },
        .{ .entry = "enemy_sineConcaveSpeeds", .site = 0x6828 },
        .{ .entry = "enemy_sineConvexSpeeds", .site = 0x67B2 },
        .{ .entry = "enemy_sineConvexSpeeds", .site = 0x67BC },
        .{ .entry = "enemy_sineConvexSpeeds", .site = 0x67EF },
        .{ .entry = "enemy_sineConvexSpeeds", .site = 0x67F9 },
        .{ .entry = "enemy_sineConvexSpeeds", .site = 0x6819 },
        .{ .entry = "enemy_sineConvexSpeeds", .site = 0x6823 },
        .{ .entry = "blobThrower_data", .site = 0x4DB1 },
        .{ .entry = "arachnus_jumpSpeedTables", .site = 0x5152 },
    }) |t| {
        const o = blocks.offsetIn(2, t.site);
        try testing.expectEqual(@as(u8, 0x21), rom[o]);
        const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
        try testing.expectEqual(addr, offsets.find(t.entry).?.gb_addr);
    }
    // 1.0 Step 12: the thrower blob's hitbox and three tables, each at the
    // offset the engine reads it at, as its reader's `LD HL,d16` names it.
    {
        const base = offsets.find("blobThrower_data").?.gb_addr;
        for ([_]struct { sym: []const u8, site: u16 }{
            .{ .sym = "ConstBlobAtBox", .site = 0x4DBF },
            .{ .sym = "ConstBlobAtTop", .site = 0x4EE5 },
            .{ .sym = "ConstBlobAtTop", .site = 0x4EED },
            .{ .sym = "ConstBlobAtTop", .site = 0x4F05 },
            .{ .sym = "ConstBlobAtMid", .site = 0x4EF5 },
            .{ .sym = "ConstBlobAtBot", .site = 0x4EFD },
        }) |t| {
            const o = blocks.offsetIn(2, t.site);
            try testing.expectEqual(@as(u8, 0x21), rom[o]);
            const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
            const at: u16 = @truncate(inject.symbol(t.sym) orelse return error.MissingSymbol);
            if (addr != base + at) {
                std.debug.print("{s} is ${X}, but 02:${X:0>4} reads 02:${X:0>4}\n", .{ t.sym, at, t.site, addr });
                bad += 1;
            }
        }
        // 1.0 Step 13: Arachnus's three jump tables, one blob, each at the
        // offset its reader's `LD HL,d16` names.
        const arach = offsets.find("arachnus_jumpSpeedTables").?.gb_addr;
        for ([_]struct { sym: []const u8, site: u16 }{
            .{ .sym = "ConstArachHigh", .site = 0x5152 },
            .{ .sym = "ConstArachMid", .site = 0x5286 },
            .{ .sym = "ConstArachLow", .site = 0x51B9 },
        }) |t| {
            const o = blocks.offsetIn(2, t.site);
            try testing.expectEqual(@as(u8, 0x21), rom[o]);
            const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
            const at: u16 = @truncate(inject.symbol(t.sym) orelse return error.MissingSymbol);
            if (addr != arach + at) {
                std.debug.print("{s} is ${X}, but 02:${X:0>4} reads 02:${X:0>4}\n", .{ t.sym, at, t.site, addr });
                bad += 1;
            }
        }
        // And the moves blob starts where the first blob's header points.
        const hdr = rom[blocks.offsetIn(2, 0x50D5)..];
        const first = @as(u16, hdr[6]) | (@as(u16, hdr[7]) << 8);
        if (first != offsets.find("blobMovementTables").?.gb_addr or first != @as(u16, @truncate(inject.symbol("ConstBlobMovesGb") orelse return error.MissingSymbol))) bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "every earthquake constant and threshold is the operand or the bytes it was read out of" {
    // Step 14. `earthquakeCheck` (08:$7EBC), the countdown in `miscIngameTasks`
    // (01:$5873), the shake and its end (01:$79EF), and the `SONG` opcode's
    // quake arm (00:$25A2). A wrong threshold is a kill that never shakes the
    // screen, which no rung that stops at the first kill would notice.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstQuakeTicks", .want = try blocks.loadIn(rom, 8, 0x7ECD), .from = "08:$7ECD LD A,d8" },
        .{ .sym = "ConstQuakeLastCount", .want = try blocks.compareIn(rom, 8, 0x7ED5), .from = "08:$7ED5 CP d8" },
        .{ .sym = "ConstQuakeTicksLast", .want = try blocks.loadIn(rom, 8, 0x7ED8), .from = "08:$7ED8 LD A,d8" },
        .{ .sym = "ConstQuakeLen", .want = try blocks.loadIn(rom, 1, 0x5884), .from = "01:$5884 LD A,d8" },
        .{ .sym = "ConstSongIntQuake", .want = try blocks.loadIn(rom, 1, 0x5889), .from = "01:$5889 LD A,d8" },
        .{ .sym = "ConstQuakeLastCount", .want = try blocks.compareIn(rom, 1, 0x5891), .from = "01:$5891 CP d8" },
        .{ .sym = "ConstQuakeLenLast", .want = try blocks.loadIn(rom, 1, 0x5895), .from = "01:$5895 LD A,d8" },
        .{ .sym = "ConstSongIntEnd", .want = try blocks.loadIn(rom, 1, 0x7A28), .from = "01:$7A28 LD A,d8" },
        .{ .sym = "ConstSongIntQuake", .want = try blocks.compareIn(rom, 0, 0x25A5), .from = "00:$25A5 CP d8" },
        .{ .sym = "ConstSongSilence", .want = try blocks.compareIn(rom, 0, 0x25AC), .from = "00:$25AC CP d8" },
        .{ .sym = "ConstSongSilence", .want = try blocks.compareIn(rom, 0, 0x25E7), .from = "00:$25E7 CP d8" },
        .{ .sym = "ConstSongRoar", .want = try blocks.compareIn(rom, 0, 0x25B6), .from = "00:$25B6 CP d8" },
        .{ .sym = "ConstSongRoar", .want = try blocks.compareIn(rom, 0, 0x25EE), .from = "00:$25EE CP d8" },
    };
    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print("{s}: engine has ${X:0>2}, the cartridge's {s} says ${X:0>2}\n", .{ c.sym, got, c.from, c.want });
            bad += 1;
        }
    }
    // The shake's two masks, `AND $02` at 01:$79F4 and `AND $04` at $7A39.
    if (try blocks.andIn(rom, 1, 0x79F4) != @as(u8, @truncate(inject.symbol("ConstQuakeShakeBit").?))) bad += 1;
    if (try blocks.andIn(rom, 1, 0x7A39) != @as(u8, @truncate(inject.symbol("ConstQuakeSamusBit").?))) bad += 1;
    // The thresholds: the table `LD HL,d16` at 08:$7EBC names, through its
    // `$FF`, against the engine's copy byte for byte.
    {
        const o = blocks.offsetIn(8, 0x7EBC);
        try testing.expectEqual(@as(u8, 0x21), rom[o]);
        const addr = @as(u16, rom[o + 1]) | (@as(u16, rom[o + 2]) << 8);
        const t = blocks.offsetIn(8, addr);
        var n: usize = 0;
        while (rom[t + n] != 0xFF) n += 1;
        const want = rom[t..][0 .. n + 1];
        const at = inject.symbolOffset("QuakeThresholds") orelse return error.MissingSymbol;
        if (!std.mem.eql(u8, inject.image[at..][0..want.len], want)) {
            std.debug.print("QuakeThresholds is not the {d} bytes at 08:${X:0>4}\n", .{ want.len, addr });
            bad += 1;
        }
        // The region's first gate is the first threshold: one kill from $47
        // opens the door and starts the quake.
        try testing.expectEqual(@as(u8, 0x46), want[0]);
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

const items = @import("items.zig");
const blocks = @import("blocks.zig");
const target = @import("snes_target.zig");

test "the spider ball's numbers are the cartridge's" {
    // Step 14b. Every constant the four spider handlers and `SpiderContacts`
    // were written from, against the instruction it came out of. The probe
    // offsets are the check that matters most: the midpoints are the ROM's own
    // operands, not averages, and a probe a pixel off reads the wrong tile only
    // at a wall's edge -- which is where the climb happens.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstSpiderXRight", .want = try blocks.addIn(rom, 0, 0x1A48), .from = "00:$1A48 ADD A,d8" },
        .{ .sym = "ConstSpiderXRight", .want = try blocks.addIn(rom, 0, 0x1AA3), .from = "00:$1AA3 ADD A,d8" },
        .{ .sym = "ConstSpiderXLeft", .want = try blocks.addIn(rom, 0, 0x1A73), .from = "00:$1A73 ADD A,d8" },
        .{ .sym = "ConstSpiderXLeft", .want = try blocks.addIn(rom, 0, 0x1ABE), .from = "00:$1ABE ADD A,d8" },
        .{ .sym = "ConstSpiderXMid", .want = try blocks.addIn(rom, 0, 0x1AD9), .from = "00:$1AD9 ADD A,d8" },
        .{ .sym = "ConstSpiderXMid", .want = try blocks.addIn(rom, 0, 0x1AFB), .from = "00:$1AFB ADD A,d8" },
        .{ .sym = "ConstSpiderYTop", .want = try blocks.addIn(rom, 0, 0x1A4F), .from = "00:$1A4F ADD A,d8" },
        .{ .sym = "ConstSpiderYTop", .want = try blocks.addIn(rom, 0, 0x1A7A), .from = "00:$1A7A ADD A,d8" },
        .{ .sym = "ConstSpiderYTop", .want = try blocks.addIn(rom, 0, 0x1AE0), .from = "00:$1AE0 ADD A,d8" },
        .{ .sym = "ConstSpiderYBottom", .want = try blocks.addIn(rom, 0, 0x1A61), .from = "00:$1A61 ADD A,d8" },
        .{ .sym = "ConstSpiderYBottom", .want = try blocks.addIn(rom, 0, 0x1A8C), .from = "00:$1A8C ADD A,d8" },
        .{ .sym = "ConstSpiderYBottom", .want = try blocks.addIn(rom, 0, 0x1AF4), .from = "00:$1AF4 ADD A,d8" },
        .{ .sym = "ConstSpiderYMid", .want = try blocks.addIn(rom, 0, 0x1AAA), .from = "00:$1AAA ADD A,d8" },
        .{ .sym = "ConstSpiderYMid", .want = try blocks.addIn(rom, 0, 0x1AC5), .from = "00:$1AC5 ADD A,d8" },
        // Every store of a spider pose, and every store a spider pose makes of
        // another one.
        .{ .sym = "ConstPoseSpider", .want = try blocks.loadIn(rom, 0, 0x178B), .from = "00:$178B LD A,d8" },
        .{ .sym = "ConstPoseSpider", .want = try blocks.loadIn(rom, 0, 0x109A), .from = "00:$109A LD A,d8" },
        .{ .sym = "ConstPoseSpiderRoll", .want = try blocks.loadIn(rom, 0, 0x1077), .from = "00:$1077 LD A,d8" },
        .{ .sym = "ConstPoseSpiderRoll", .want = try blocks.loadIn(rom, 0, 0x1241), .from = "00:$1241 LD A,d8" },
        .{ .sym = "ConstPoseSpiderFall", .want = try blocks.loadIn(rom, 0, 0x1043), .from = "00:$1043 LD A,d8" },
        .{ .sym = "ConstPoseSpiderFall", .want = try blocks.loadIn(rom, 0, 0x107D), .from = "00:$107D LD A,d8" },
        .{ .sym = "ConstPoseSpiderFall", .want = try blocks.loadIn(rom, 0, 0x11DA), .from = "00:$11DA LD A,d8" },
        .{ .sym = "ConstPoseSpiderFall", .want = try blocks.loadIn(rom, 0, 0x1258), .from = "00:$1258 LD A,d8" },
        .{ .sym = "ConstPoseSpiderFall", .want = try blocks.loadIn(rom, 0, 0x0ED8), .from = "00:$0ED8 LD A,d8" },
        .{ .sym = "ConstPoseSpiderJump", .want = try blocks.loadIn(rom, 0, 0x17AC), .from = "00:$17AC LD A,d8" },
    };
    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print("{s} is ${X:0>2}, the cartridge's {s} is ${X:0>2}\n", .{ c.sym, got, c.from, c.want });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // The item every Down arm tests is the bit `BIT 5,A` names, at all four.
    const spider: u8 = @truncate(inject.symbol("ConstItemSpider") orelse return error.MissingSymbol);
    for ([_]u16{ 0x0ED4, 0x1254, 0x1788, 0x17A8 }) |at| {
        try testing.expectEqual(@as(u8, 0xCB), rom[at]);
        try testing.expectEqual(@as(u8, 0x47), rom[at + 1] & 0xC7); // BIT n,A
        try testing.expectEqual(@as(u8, 1) << @intCast((rom[at + 1] >> 3) & 7), spider);
    }

    // The table rows: the four `LD HL,d16`s into `spiderDirectionTable`, as
    // offsets from its first, are the engine's row constants.
    const base = offsets.find("spiderDirectionTable").?.gb_addr;
    const try2: u16 = @truncate(inject.symbol("ConstSpiderTry2") orelse return error.MissingSymbol);
    const cw: u16 = @truncate(inject.symbol("ConstSpiderCw") orelse return error.MissingSymbol);
    const Load = struct { at: u16, row: u16 };
    for ([_]Load{
        .{ .at = 0x10B7, .row = 0 },
        .{ .at = 0x10BF, .row = cw },
        .{ .at = 0x10FD, .row = try2 },
        .{ .at = 0x1105, .row = try2 + cw },
    }) |l| {
        try testing.expectEqual(@as(u8, 0x21), rom[l.at]);
        try testing.expectEqual(base + l.row, std.mem.readInt(u16, rom[l.at + 1 ..][0..2], .little));
    }
    try testing.expectEqual(@as(u8, 0x21), rom[0x106F]);
    try testing.expectEqual(
        offsets.find("spiderBallOrientationTable").?.gb_addr,
        std.mem.readInt(u16, rom[0x1070..][0..2], .little),
    );

    // `$12` is its own handler, not `$11`'s: the pose table's entries differ,
    // and the one `PoseMorphBombed` was written from is 00:$0ECB.
    const bombed: u16 = @truncate(inject.symbol("ConstPoseMorphBombed") orelse return error.MissingSymbol);
    try testing.expectEqual(@as(u16, 0x0ECB), std.mem.readInt(u16, rom[0x0D4B + 2 * bombed ..][0..2], .little));
    try testing.expect(std.mem.readInt(u16, rom[0x0D4B + 2 * (bombed - 1) ..][0..2], .little) != 0x0ECB);

    // And the sprite: two bases of `pose_sprites_spider`'s two runs of four.
    const e = offsets.find("pose_sprites_spider") orelse return error.Missing;
    const t = try sprites.parsePoseTable(a, rom[e.romOffset()..e.romEnd()]);
    defer a.free(t.ids);
    const l: u8 = @truncate(inject.symbol("ConstSprSpiderL") orelse return error.MissingSymbol);
    const r: u8 = @truncate(inject.symbol("ConstSprSpiderR") orelse return error.MissingSymbol);
    try testing.expectEqual(t.at(0)[0], l);
    try testing.expectEqual(t.at(1)[0], r);
}

const save = @import("save.zig");

test "the save station's numbers are the cartridge's, and the writer stores in the record's order" {
    // Step 15a. The constants first, each against the instruction it came out
    // of, then the magic, then the order: `save.fields` is the ROM's own writer
    // decoded, and every store `SaveFileToSram` makes must put the same Game
    // Boy variable at the same offset.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstSaveCooldown", .want = try blocks.loadIn(rom, 1, 0x583E), .from = "01:$583E LD A,d8" },
        .{ .sym = "ConstSaveTextY", .want = try blocks.loadIn(rom, 1, 0x5849), .from = "01:$5849 LD A,d8" },
        .{ .sym = "ConstSaveTextY", .want = try blocks.loadIn(rom, 1, 0x5864), .from = "01:$5864 LD A,d8" },
        .{ .sym = "ConstSaveTextX", .want = try blocks.loadIn(rom, 1, 0x584D), .from = "01:$584D LD A,d8" },
        .{ .sym = "ConstSaveTextX", .want = try blocks.loadIn(rom, 1, 0x5868), .from = "01:$5868 LD A,d8" },
        .{ .sym = "ConstSprSaveCompleted", .want = try blocks.loadIn(rom, 1, 0x5851), .from = "01:$5851 LD A,d8" },
        .{ .sym = "ConstSprSavePressStart", .want = try blocks.loadIn(rom, 1, 0x586C), .from = "01:$586C LD A,d8" },
        .{ .sym = "ConstSfxSaved", .want = try blocks.loadIn(rom, 1, 0x7B78), .from = "01:$7B78 LD A,d8" },
        .{ .sym = "ConstSfxSaved", .want = try blocks.loadIn(rom, 1, 0x7B7D), .from = "01:$7B7D LD A,d8" },
        .{ .sym = "ConstIgtPeriods", .want = try blocks.compareIn(rom, 0, 0x0337), .from = "00:$0337 CP d8" },
    };
    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print("{s} is ${X:0>2}, the cartridge's {s} is ${X:0>2}\n", .{ c.sym, got, c.from, c.want });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // The save tile's bit, at both probes of `collision_samusBottom`.
    const bit: u8 = @truncate(inject.symbol("ConstBlockSave") orelse return error.MissingSymbol);
    for ([_]u16{ 0x1F4F, 0x1F92 }) |at| {
        try testing.expectEqual(@as(u8, 0xCB), rom[at]);
        try testing.expectEqual(@as(u8, 0x47), rom[at + 1] & 0xC7); // BIT n,A
        try testing.expectEqual(@as(u8, 1) << @intCast((rom[at + 1] >> 3) & 7), bit);
    }

    // The magic, byte for byte.
    const m = inject.symbolOffset("SaveMagic") orelse return error.MissingSymbol;
    try testing.expectEqualSlices(u8, rom[save.magic_addr..][0..save.magic_len], inject.image[m..][0..save.magic_len]);

    // The order. Which port variable stands for which Game Boy one is the claim
    // written here, once; which offset each Game Boy variable goes to is the
    // ROM's, through `save.fields`.
    const Stands = struct { define: []const u8, gb: u16 };
    const stands = [_]Stands{
        .{ .define = "Items", .gb = 0xD045 },     .{ .define = "Beam", .gb = 0xD055 },
        .{ .define = "Tanks", .gb = 0xD050 },     .{ .define = "HealthLo", .gb = 0xD051 },
        .{ .define = "HealthHi", .gb = 0xD052 },  .{ .define = "MaxMissLo", .gb = 0xD081 },
        .{ .define = "MaxMissHi", .gb = 0xD082 }, .{ .define = "CurMissLo", .gb = 0xD053 },
        .{ .define = "CurMissHi", .gb = 0xD054 }, .{ .define = "Facing", .gb = 0xD02B },
        .{ .define = "AcidDmg", .gb = 0xD077 },   .{ .define = "SpikeDmg", .gb = 0xD078 },
        .{ .define = "MetReal", .gb = 0xD089 },   .{ .define = "Song", .gb = 0xD092 },
        .{ .define = "IgtMinutes", .gb = 0xD098 }, .{ .define = "IgtHours", .gb = 0xD099 },
        .{ .define = "MetDisp", .gb = 0xD09A },
    };
    const src = @import("residue.zig").engine_source;
    const body_at = std.mem.indexOf(u8, src, "\nSaveFileToSram:\n") orelse return error.MissingSymbol;
    // To its `rtl`: it is in bank 1 since 1.0 Step 6, apart from `SaveMagic`.
    const body_end = std.mem.indexOfPos(u8, src, body_at + 1, "\n        rtl\n") orelse return error.MissingSymbol;
    var lines = std.mem.splitScalar(u8, src[body_at..body_end], '\n');
    var last: ?[]const u8 = null;
    var checked: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, ';')) |c| raw[0..c] else raw, " \t");
        if (std.mem.startsWith(u8, line, "lda")) {
            const bang = std.mem.indexOfScalar(u8, line, '!') orelse continue;
            last = line[bang + 1 ..];
            continue;
        }
        const prefix = "sta.l !SRAM+$";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        // Indexed by the slot's offset since Step 24i.
        const operand = line[prefix.len..];
        const hex = if (std.mem.endsWith(u8, operand, ",x")) operand[0 .. operand.len - 2] else operand;
        const off = std.fmt.parseInt(u8, hex, 16) catch continue;
        if (off < 0x1D) continue; // position, camera and the save-buffer block
        const define = last orelse return error.TestUnexpectedResult;
        var gb: ?u16 = null;
        for (stands) |s| if (std.mem.eql(u8, s.define, define)) {
            gb = s.gb;
        };
        var want: ?u16 = null;
        for (save.fields) |f| if (f.offset == off) {
            want = f.src;
        };
        if (gb == null or want == null or gb.? != want.?) {
            std.debug.print("SaveFileToSram stores !{s} at +${X:0>2}, where the cartridge stores ${X:0>4}\n", .{ define, off, want orelse 0 });
            bad += 1;
        }
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
    // Seventeen single stores, offsets $1D to $2D: every one the record has.
    try testing.expectEqual(@as(usize, save.record_len - 0x1D), checked);
}

const convert = @import("snes_convert.zig");

test "the load reads the save buffer into the variables the cartridge's load does" {
    // Step 15b. The title's constants against their instructions, the load
    // table's layout against the converter that builds it, and then every store
    // `LoadGameState` makes: a `lda.w !SaveBuf+!SB_x` names a buffer byte, the
    // `sta`s after it name port variables, and the ROM's own load
    // (`loadGame_samusData` 00:$0CA3, `gameMode_LoadA` 00:$03B5) says which
    // Game Boy variables that byte goes to.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const sym = struct {
        fn get(name: []const u8) !u16 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.get;
    try testing.expectEqual(@as(u16, try blocks.loadIn(rom, 5, 0x425A)), try sym("ConstSfxSelect"));
    try testing.expectEqual(@as(u16, convert.no_source_bank), try sym("ConstCopyNoSource"));
    try testing.expectEqual(@as(u16, convert.load_font_entry_at), try sym("ConstLsFont"));
    try testing.expectEqual(@as(u16, convert.load_entries_at), try sym("ConstLsEntries"));
    // `ITEM`'s transfers (Step 24): where the load table keeps them, and what
    // the opcode waits, from the lengths the ROM's arm hands $27BA. The
    // duration model's own list is held to the same lengths.
    try testing.expectEqual(@as(u16, convert.load_item_at), try sym("ConstLsItem"));
    try testing.expectEqual(@as(u16, convert.load_item_tiles_at), try sym("ConstLsItemTiles"));
    const arm = convert.itemArm(rom) orelse return error.NoItemArm;
    var item_wait: usize = 0;
    for (arm.lens(), @import("transition.zig").item_bytes) |len, model| {
        try testing.expectEqual(model, @as(usize, len));
        item_wait += @import("transition.zig").copyFrames(len);
    }
    try testing.expectEqual(@as(u16, @intCast(item_wait)), try sym("ConstItemWait"));
    // The title's slot check, 05:$4284 `CP $08`, and the counter it writes.
    try testing.expectEqual(@as(u8, 0x08), try blocks.compareIn(rom, 5, 0x4284));
    try testing.expectEqualSlices(u8, &.{ 0xEA, 0xC0, 0xA0 }, rom[5 * 0x4000 + 0x0290 ..][0..3]);

    const src = @import("residue.zig").engine_source;
    const sbValue = struct {
        fn get(s: []const u8, name: []const u8) !u8 {
            var buf: [48]u8 = undefined;
            const needle = try std.fmt.bufPrint(&buf, "\n!{s}", .{name});
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, s, at, needle)) |i| : (at = i + 1) {
                const rest = std.mem.trimStart(u8, s[i + needle.len ..], " ");
                if (!std.mem.startsWith(u8, rest, "= $")) continue;
                const end = std.mem.indexOfAny(u8, rest[3..], " \n;") orelse continue;
                return std.fmt.parseInt(u8, rest[3..][0..end], 16);
            }
            return error.MissingSymbol;
        }
    }.get;

    // Which Game Boy variables the ROM's load puts buffer byte `b` into.
    const Loads = struct {
        fn targets(r: []const u8, b: u8, out: *[4]u16) usize {
            var n: usize = 0;
            const ranges = [_][2]u16{ .{ 0x0CA3, 0x0D0C }, .{ 0x03B5, 0x0464 } };
            for (ranges) |rg| {
                var i: usize = rg[0];
                while (i + 3 <= rg[1]) : (i += 1) {
                    if (r[i] != 0xFA or r[i + 1] != b or r[i + 2] != 0xD8) continue;
                    var j = i + 3;
                    while (r[j] == 0xEA and n < out.len) : (j += 3) {
                        out[n] = std.mem.readInt(u16, r[j + 1 ..][0..2], .little);
                        n += 1;
                    }
                }
            }
            return n;
        }
    };

    const Stands = struct { define: []const u8, gb: u16 };
    const stands = [_]Stands{
        .{ .define = "Items", .gb = 0xD045 },       .{ .define = "Beam", .gb = 0xD055 },
        .{ .define = "ActiveWeapon", .gb = 0xD04D }, .{ .define = "Tanks", .gb = 0xD050 },
        .{ .define = "HealthLo", .gb = 0xD051 },    .{ .define = "DispHealthLo", .gb = 0xD084 },
        .{ .define = "MaxMissLo", .gb = 0xD081 },   .{ .define = "CurMissLo", .gb = 0xD053 },
        .{ .define = "DispMissLo", .gb = 0xD086 },  .{ .define = "Facing", .gb = 0xD02B },
        .{ .define = "AcidDmg", .gb = 0xD077 },     .{ .define = "SpikeDmg", .gb = 0xD078 },
        .{ .define = "MetReal", .gb = 0xD089 },     .{ .define = "Song", .gb = 0xD092 },
        .{ .define = "IgtMinutes", .gb = 0xD098 },  .{ .define = "IgtHours", .gb = 0xD099 },
        .{ .define = "MetDisp", .gb = 0xD09A },     .{ .define = "Solid", .gb = 0xD056 },
        .{ .define = "SolidEnemy", .gb = 0xD069 },  .{ .define = "SolidBeam", .gb = 0xD08A },
    };

    const body_at = std.mem.indexOf(u8, src, "\nLoadGameState:\n") orelse return error.MissingSymbol;
    const body_end = std.mem.indexOfPos(u8, src, body_at + 1, "\nBootGraphics:\n") orelse return error.MissingSymbol;
    var lines = std.mem.splitScalar(u8, src[body_at..body_end], '\n');
    var from: ?u8 = null;
    var bad: usize = 0;
    var checked: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, ';')) |c| raw[0..c] else raw, " \t");
        if (std.mem.startsWith(u8, line, "lda")) {
            const pre = "lda.w !SaveBuf+!";
            from = if (std.mem.startsWith(u8, line, pre)) blk: {
                const name = line[pre.len..];
                const plus = std.mem.indexOfScalar(u8, name, '+');
                const base = try sbValue(src, name[0 .. plus orelse name.len]);
                break :blk base + if (plus) |p| try std.fmt.parseInt(u8, name[p + 1 ..], 10) else 0;
            } else null;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "sta")) continue;
        const b = from orelse continue;
        const bang = std.mem.indexOfScalar(u8, line, '!') orelse continue;
        const define = line[bang + 1 ..];
        var gb: ?u16 = null;
        for (stands) |s| if (std.mem.eql(u8, s.define, define)) {
            gb = s.gb;
        };
        var t: [4]u16 = undefined;
        const n = Loads.targets(rom, b, &t);
        const ok = gb != null and std.mem.indexOfScalar(u16, t[0..n], gb.?) != null;
        if (!ok) {
            std.debug.print("LoadGameState puts buffer byte ${X:0>2} into !{s}, which the cartridge's load does not\n", .{ b, define });
            bad += 1;
        }
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expectEqual(stands.len, checked);
}

test "the death's numbers are the cartridge's" {
    // Step 15c. Each constant against the instruction it came out of. The two
    // 16-bit operands -- the erase stride and the text's tilemap address -- are
    // read whole, and the address is taken apart into the row and column the
    // engine keeps.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstNoiseKilled", .want = try blocks.loadIn(rom, 0, 0x2FA5), .from = "00:$2FA5 LD A,d8" },
        .{ .sym = "ConstDeathSteps", .want = try blocks.loadIn(rom, 0, 0x2FB0), .from = "00:$2FB0 LD A,d8" },
        .{ .sym = "ConstModeDying", .want = try blocks.loadIn(rom, 0, 0x2FC3), .from = "00:$2FC3 LD A,d8" },
        .{ .sym = "ConstDeathEvery", .want = try blocks.andIn(rom, 0, 0x2FE9), .from = "00:$2FE9 AND d8" },
        .{ .sym = "ConstDeathEnd", .want = try blocks.compareIn(rom, 0, 0x3003), .from = "00:$3003 CP d8" },
        .{ .sym = "ConstDeathDead", .want = try blocks.loadIn(rom, 0, 0x3010), .from = "00:$3010 LD A,d8" },
        .{ .sym = "ConstModeDead", .want = try blocks.loadIn(rom, 0, 0x3015), .from = "00:$3015 LD A,d8" },
        .{ .sym = "ConstNoiseKilled", .want = try blocks.compareIn(rom, 0, 0x36B9), .from = "00:$36B9 CP d8" },
        .{ .sym = "ConstGameOverEnd", .want = try blocks.compareIn(rom, 0, 0x36ED), .from = "00:$36ED CP d8" },
        .{ .sym = "ConstGameOverTimer", .want = try blocks.loadIn(rom, 0, 0x3707), .from = "00:$3707 LD A,d8" },
        .{ .sym = "ConstModeGameOver", .want = try blocks.loadIn(rom, 0, 0x370C), .from = "00:$370C LD A,d8" },
        .{ .sym = "ConstGameOverStart", .want = try blocks.compareIn(rom, 0, 0x3729), .from = "00:$3729 CP d8" },
        .{ .sym = "ConstDeathNoise", .want = try blocks.loadIn(rom, 4, 0x57FD), .from = "04:$57FD LD A,d8" },
        .{ .sym = "ConstGameOverClear", .want = try blocks.loadIn(rom, 0, 0x0381), .from = "00:$0381 LD A,d8" },
    };
    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print("{s} is ${X:0>2}, the cartridge's {s} is ${X:0>2}\n", .{ c.sym, got, c.from, c.want });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    const sym = struct {
        fn get(name: []const u8) !u16 {
            return @truncate(inject.symbol(name) orelse return error.MissingSymbol);
        }
    }.get;
    // 00:$2FFC `LD DE,$0020`.
    try testing.expectEqual(@as(u8, 0x11), rom[0x2FFC]);
    try testing.expectEqual(std.mem.readInt(u16, rom[0x2FFD..][0..2], .little), try sym("ConstDeathStride"));
    // 00:$36E9 `LD DE,$9906`: the background tilemap at $9800, row by 32.
    try testing.expectEqual(@as(u8, 0x11), rom[0x36E9]);
    const dest = std.mem.readInt(u16, rom[0x36EA..][0..2], .little) - 0x9800;
    try testing.expectEqual(dest / 32, try sym("ConstGameOverRow"));
    try testing.expectEqual(dest % 32, try sym("ConstGameOverCol"));
    // 00:$3700 `LD A,$C3`: the window's enable bit is clear, which is why the
    // band is the play field's.
    try testing.expectEqual(@as(u8, 0), try blocks.loadIn(rom, 0, 0x3700) & 0x20);
    // `killSamus`' flag, 00:$2FBE `LD A,$01`, is written as a literal.
    try testing.expectEqual(@as(u8, 0x01), try blocks.loadIn(rom, 0, 0x2FBE));
    // And the frames the cart blanks for are the ones the Game Boy's LCD is off.
    try testing.expectEqual(@as(u16, @intCast(@import("death.zig").on_timer.blankLen())), try sym("ConstGameOverBlank"));
    // 1.0 Step 22: the credits' setup, the Game Boy's LCD-off pass in frames.
    try testing.expectEqual(@as(u16, @intCast(@import("credits.zig").setup_frames)), try sym("ConstCreditsSetup"));
    // The three tables are the ones their loads name, and the engine's
    // constants are the operands: 05:$587F `LD HL,$5877`, $5906 `LD HL,$5B14`
    // with $590C `LD B,$10`, 00:$3C72 `LD HL,$7920` into $3C75's `LD DE,$A800`,
    // and $589F `CP $0E`.
    for ([_]struct { bank: u8, at: u16, name: []const u8 }{
        .{ .bank = 5, .at = 0x587F, .name = "credits_paletteFade" },
        .{ .bank = 5, .at = 0x5906, .name = "credits_starPositions" },
        .{ .bank = 0, .at = 0x3C72, .name = "creditsText" },
    }) |l| {
        const o = blocks.offsetIn(l.bank, l.at);
        try testing.expectEqual(@as(u8, 0x21), rom[o]);
        try testing.expectEqual(offsets.find(l.name).?.gb_addr, std.mem.readInt(u16, rom[o + 1 ..][0..2], .little));
    }
    try testing.expectEqual(@as(u16, rom[blocks.offsetIn(5, 0x590D)]), try sym("ConstCreditsStarCopy"));
    try testing.expectEqual(@as(u16, rom[blocks.offsetIn(5, 0x58A0)]), try sym("ConstCreditsFadeEnd"));
    try testing.expectEqual(std.mem.readInt(u16, rom[blocks.offsetIn(0, 0x3C76)..][0..2], .little), try sym("ConstCreditsTextBuf"));
}

test "Samus goes behind by the cartridge's rule, and the engine's play priority is the converter's" {
    // Step 24e. The rule is three sites, read here as the instructions they are
    // so a cartridge that differed would fail rather than be ported from a name.
    // `room.zig` measures the same rule on the running Game Boy.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // 00:$3EF1: the transition word's high byte, its bit 3 to bit 0, inverted,
    // into $D057. `INC HL / LD A,(HL) / SWAP A / RLC A / AND 1 / XOR 1 / LD (a16),A`.
    try testing.expectEqualSlices(u8, &.{ 0x23, 0x7E, 0xCB, 0x37, 0xCB, 0x07, 0xE6, 0x01, 0xEE, 0x01, 0xEA, 0x57, 0xD0 }, rom[0x3EF1..][0..13]);
    // 01:$4BA1: while $D057 is zero, bit 7 on the part just written.
    // `LD A,(a16) / AND A / JR NZ,+4 / LD A,(HL) / SET 7,A / LD (HL),A`.
    try testing.expectEqualSlices(u8, &.{ 0xFA, 0x57, 0xD0, 0xA7, 0x20, 0x04, 0x7E, 0xCB, 0xFF, 0x77 }, rom[0x4BA1..][0..10]);
    // 01:$4E18: zeroed once she is drawn.
    try testing.expectEqualSlices(u8, &.{ 0xEA, 0x57, 0xD0, 0xC9 }, rom[0x4E18..][0..4]);

    // Priority 0 only goes under BG3 if BG3's word has the bit, and the
    // engine's own writers must set the same one the converter bakes.
    const got = inject.symbol("ConstPlayPri") orelse return error.MissingSymbol;
    try testing.expectEqual(@as(u32, target.play_priority) << 13, got);
    try testing.expectEqual(@as(u1, 1), target.play_priority);
}

test "the title's menu is the cartridge's: every constant, the cursor's table and the slot's stride" {
    // Step 24h. Each constant against the instruction it came out of, where the
    // routine names it twice both sites; the cursor table against 05:$42E1's
    // bytes, read out of the engine image; and the object window the title's
    // characters are twinned into against `title_loadGraphics`'s destination.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    const Const = struct { sym: []const u8, want: u8, from: []const u8 };
    const consts = [_]Const{
        .{ .sym = "ConstTitleStartY", .want = try blocks.loadIn(rom, 5, 0x417B), .from = "05:$417B LD A,d8" },
        .{ .sym = "ConstTitleClearY", .want = try blocks.loadIn(rom, 5, 0x4185), .from = "05:$4185 LD A,d8" },
        .{ .sym = "ConstTitleCursorX", .want = try blocks.loadIn(rom, 5, 0x4189), .from = "05:$4189 LD A,d8" },
        .{ .sym = "ConstTitleCursorMask", .want = try blocks.andIn(rom, 5, 0x4192), .from = "05:$4192 AND d8" },
        .{ .sym = "ConstSprTitleNumber", .want = try blocks.addIn(rom, 5, 0x41A8), .from = "05:$41A8 ADD A,d8" },
        .{ .sym = "ConstTitleWordX", .want = try blocks.loadIn(rom, 5, 0x41AF), .from = "05:$41AF LD A,d8" },
        .{ .sym = "ConstTitleStartY", .want = try blocks.loadIn(rom, 5, 0x41B3), .from = "05:$41B3 LD A,d8" },
        .{ .sym = "ConstSprTitleStart", .want = try blocks.loadIn(rom, 5, 0x41B7), .from = "05:$41B7 LD A,d8" },
        .{ .sym = "ConstTitleClearY", .want = try blocks.loadIn(rom, 5, 0x41C4), .from = "05:$41C4 LD A,d8" },
        .{ .sym = "ConstSprTitleClear", .want = try blocks.loadIn(rom, 5, 0x41C8), .from = "05:$41C8 LD A,d8" },
        .{ .sym = "ConstSfxSelect", .want = try blocks.loadIn(rom, 5, 0x41D8), .from = "05:$41D8 LD A,d8" },
        .{ .sym = "ConstSfxSelect", .want = try blocks.loadIn(rom, 5, 0x4241), .from = "05:$4241 LD A,d8" },
        .{ .sym = "ConstNoiseCleared", .want = try blocks.loadIn(rom, 5, 0x42A6), .from = "05:$42A6 LD A,d8" },
        .{ .sym = "ConstHudWY", .want = try blocks.loadIn(rom, 5, 0x40C0), .from = "05:$40C0 LD A,d8" },
        // Step 24i: the two steps' sound, the wrap and the seed's bound.
        .{ .sym = "ConstSfxSelect", .want = try blocks.loadIn(rom, 5, 0x41F1), .from = "05:$41F1 LD A,d8" },
        .{ .sym = "ConstSfxSelect", .want = try blocks.loadIn(rom, 5, 0x4211), .from = "05:$4211 LD A,d8" },
        .{ .sym = "ConstSaveSlots", .want = try blocks.compareIn(rom, 5, 0x41FD), .from = "05:$41FD CP d8" },
        .{ .sym = "ConstSaveSlots", .want = try blocks.compareIn(rom, 0, 0x02BD), .from = "00:$02BD CP d8" },
        .{ .sym = "ConstSlotLast", .want = try blocks.loadIn(rom, 5, 0x4221), .from = "05:$4221 LD A,d8" },
    };
    var bad: usize = 0;
    for (consts) |c| {
        const got: u8 = @truncate(inject.symbol(c.sym) orelse return error.MissingSymbol);
        if (got != c.want) {
            std.debug.print("{s} is ${X:0>2}, the cartridge's {s} is ${X:0>2}\n", .{ c.sym, got, c.from, c.want });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);

    // `titleCursorTable`, the four bytes `LD HL,$42E1` at 05:$419B names.
    try testing.expectEqual(@as(u8, 0x21), rom[blocks.offsetIn(5, 0x419B)]);
    const table_at = std.mem.readInt(u16, rom[blocks.offsetIn(5, 0x419C)..][0..2], .little);
    const table = rom[blocks.offsetIn(5, table_at)..][0..4];
    const engine = inject.image[inject.symbolOffset("TitleCursorTable") orelse return error.MissingSymbol ..][0..4];
    try testing.expectEqualSlices(u8, table, engine);

    // The record's stride: `SLA A / SLA A / SWAP A` is six shifts, at the
    // clear, Start's walk, the load and the save alike, and the engine's.
    const shifts = [_]u8{ 0xCB, 0x27, 0xCB, 0x27, 0xCB, 0x37 };
    for ([_]struct { bank: u8, addr: u16 }{ .{ .bank = 5, .addr = 0x42AE }, .{ .bank = 5, .addr = 0x4273 }, .{ .bank = 1, .addr = 0x4E41 }, .{ .bank = 1, .addr = 0x7AEA } }) |at| {
        try testing.expectEqualSlices(u8, &shifts, rom[blocks.offsetIn(at.bank, at.addr)..][0..6]);
    }
    const slot_shift: u5 = @intCast(inject.symbol("ConstSlotShift") orelse return error.MissingSymbol);
    try testing.expectEqual(@as(u5, 6), slot_shift);
    try testing.expectEqual(@as(u32, save.slot_size), @as(u32, 1) << slot_shift);
    // Step 24i. The spawn flags' stride: the slot doubled into the high byte
    // of $B000 (`LD DE,$B000` / `ADD A,A` / `ADD A,D` at 01:$7A9D, and the
    // load's `ADD A,H` at $7ACA), $200 a slot, $1000 past the slots.
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x00, 0xB0, 0xFA, 0xA3, 0xD0, 0x87, 0x82 }, rom[blocks.offsetIn(1, 0x7A9D)..][0..8]);
    try testing.expectEqualSlices(u8, &.{ 0x21, 0x00, 0xB0, 0xFA, 0xA3, 0xD0, 0x87, 0x84 }, rom[blocks.offsetIn(1, 0x7AC4)..][0..8]);
    const spawn_shift: u5 = @intCast(inject.symbol("ConstSpawnSlotShift") orelse return error.MissingSymbol);
    try testing.expectEqual(@as(u32, 2 * 0x100), @as(u32, 1) << spawn_shift);
    // Left's wrap is `CP $FF` on the decremented slot, which the engine
    // compares with the same byte.
    try testing.expectEqual(@as(u8, 0xFF), try blocks.compareIn(rom, 5, 0x421D));

    // The twin's first object id is where the title's copy lands under the
    // objects' unsigned addressing: ($8800 - $8000) / 16.
    const copy = convert.titleCopy(rom) orelse return error.MissingSymbol;
    try testing.expectEqual(@as(u32, (copy.dest - 0x8000) / 16), @as(u32, @truncate(inject.symbol("ConstTitleObjFirst") orelse return error.MissingSymbol)));
}
