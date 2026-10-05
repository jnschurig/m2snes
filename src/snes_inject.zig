//! The injector: the assembled engine image plus the converted asset set,
//! placed into the regions `snes_layout.zig` reserves, patched, and emitted as
//! a SNES ROM.
//!
//! ## Why the engine arrives pre-assembled
//!
//! `01-requirements.md` promises that an end user needs one binary and their
//! own cartridge dump. Shipping the 65816 source instead would put an assembler
//! on that list, so `engine/main.asm` is assembled at dev time by
//! `tools/build-engine.sh` and the resulting image and symbol file are
//! committed. They are our own original code and contain nothing derived from
//! anyone's ROM; `src/policy.zig` allow-lists the image by path and says why.
//!
//! ## The patch table is the whole interface
//!
//! The engine and the layout manifest are separate sources of truth - one lives
//! in an assembler, the other in Zig - so the engine never names a region
//! address. It carries a table at the `RegionTable` symbol, filled with $FF,
//! and this file writes one entry per `layout.Class` into it. The table opens
//! with a magic word, a version, a class count, and an entry size, all of which
//! are checked before a byte is written: an image built against a different
//! manifest is refused rather than patched into a plausible-looking wreck.
//!
//! ## The directory
//!
//! Region bases alone are not enough to find anything. A converted `COPY`
//! carries an *asset id* and a delta - see `snes_convert.emitCopy` - so the
//! engine has to turn an id into an address at runtime. The directory is that
//! map: one eight-byte entry per blob, grouped by class in placement order,
//! with the id the converted stream refers to. It is the one class the
//! converter does not produce, which is why `layout` sizes it from the set
//! rather than measuring it.
//!
//! ## Determinism
//!
//! The same input ROM and the same builder must produce the same output bytes.
//! Nothing here reads a clock, a path, an environment variable, or a hash map
//! in iteration order: every list walked is a slice in the order the converter
//! built it, and the packing rule is `layout.place`, the same function
//! `layout.measure` validates with. `digest` is what the gate compares.

const std = @import("std");
const convert = @import("snes_convert.zig");
const layout = @import("snes_layout.zig");
const target = @import("snes_target.zig");
const screen = @import("snes_screen.zig");
const render = @import("snes_render.zig");
const screens = @import("screens.zig");
const offsets_table = @import("offsets.zig");
const gfx_info = @import("gfx_info.zig");

/// The assembled engine, committed. Both are imported rather than read from
/// disk so the shipped builder is a single file with no data directory.
pub const image = @embedFile("engine_bin");
pub const symbols = @embedFile("engine_sym");

// ---- The patch table, mirrored from engine/main.asm -------------------------

pub const patch_magic = "M2RG";
pub const patch_version: u8 = 1;
/// u24 region base, u24 directory address, u16 blob count.
pub const region_entry_bytes: usize = 8;
/// u24 address, u8 id, u16 length, u16 reserved.
pub const directory_entry_bytes: usize = layout.directory_entry_bytes;

// ---- The boot record, mirrored from engine/main.asm -------------------------
//
// A second patch table, checked the same way and for the same reason. It
// carries the one thing the engine cannot derive: *which* screen to draw. The
// map index and cell say where, the door index says which script to replay to
// fill VRAM, and the tile table is what that script leaves selected when it
// selects nothing itself.

pub const boot_magic = "M2BT";
pub const boot_version: u8 = 17;
/// magic, version, map index, cell, tile table, door index, four background
/// palette words, Samus's character-sheet id, eight object palette words, her
/// start position as a world coordinate on each axis, her starting pose, the
/// camera's start on each axis, the frame counter's seed, and which way she is
/// facing, the pad she was booted mid-press of, how long the pose she boots in
/// waits, where all of it came from, and the assets its title screen is made
/// of, and how many tiles the record forces into the world after the room is
/// drawn, and what she is carrying, and what she has equipped, and the song,
/// and the room's own song, and the damage acid and spikes do, and the title's
/// first sheet as objects, and the new game's save record.
/// Version 17 appended `initialSaveFile`; version 16 appended the title's object sheet; version 15 appended the two damage values; version 14 appended the room song; version 13 appended the song; version 12 appended the items, beam and weapon; version 11 appended the loadout; version 10
/// appended that count; version 9 appended the title screen;
/// version 8 appended the countdown
/// and the mode; version 7 appended the pad; version 6 appended the facing;
/// version 5 appended the counter; version 4 appended the camera; version 3
/// appended the position and pose; version 2 appended the sheet id and the
/// object palettes; version 1 ended at the background palette.
pub const boot_record_bytes: usize = 78 + screen.save_record_len;
/// Where Samus's `chr_obj` asset id sits within the record.
pub const boot_samus_chr_at: usize = 18;
/// And where the two object palettes begin.
pub const boot_obj_palette_at: usize = 19;
/// Samus's start, as `(screen << 8) | pixel` on each axis -- the same shape the
/// Game Boy's position pairs use, so `room.Placement.worldX` and this field are
/// directly comparable. Y first, matching the engine's declaration order.
pub const boot_samus_y_at: usize = 35;
pub const boot_samus_x_at: usize = 37;
/// The pose she starts in.
pub const boot_pose_at: usize = 39;
/// Where the camera starts, same shape as the position and read separately from
/// it. Y first, matching the engine. See `snes_screen.Boot.cam_x` for why it is
/// not derived from her position any more.
pub const boot_cam_y_at: usize = 40;
pub const boot_cam_x_at: usize = 42;
/// What `InitState` seeds `!FrameCount` with. Physics, not bookkeeping: the
/// walk's 1/2 alternation is `!FrameCount & 1`, the same expression the
/// original evaluates on $FF97 at 00:$1C25.
pub const boot_frame_count_at: usize = 44;
/// Which way she is facing: $01 right, $00 left, the original's own convention.
/// Physics, not decoration -- the standing and running handlers branch on it
/// before they move her, so a cart that boots facing the wrong way loses a
/// frame turning and never gets it back.
pub const boot_facing_at: usize = 48;
/// The pad word `InitState` seeds `!PadHeld` with, in the engine's `!PAD_*`
/// bits. See `engine/main.asm`'s `BootInput`.
pub const boot_input_at: usize = 46;
/// What `InitState` seeds `!Countdown` with: how many frames the pose she boots
/// in waits before it hands over control. Zero for every pose but $13.
pub const boot_countdown_at: usize = 49;
/// Whether the record is the game's own new game or a handover measured
/// mid-run. The engine does not branch on it -- it reads the record the same
/// way either way -- but a cart carries the answer so a person holding one can
/// tell which they have, and so the gate can refuse to grade the wrong kind.
pub const boot_mode_at: usize = 51;
/// The four `chr_bg` assets the title screen's characters come from, in the
/// order the Game Boy's one 4 KiB copy walks them, and the `tilemap` asset the
/// screen itself is. Five ids; `$FF` ends the character list early.
pub const boot_title_chr_at: usize = 52;
pub const boot_title_chr_count: usize = 4;
pub const boot_title_map_at: usize = 56;
/// Version 10. How many of `BootWorld`'s entries `SeedWorld` applies.
pub const boot_world_count_at: usize = 57;
/// Version 11. What she is carrying: energy tanks, health, the missile ceiling
/// and count, and the two Metroid counts, as `snes_screen.Loadout` holds them.
pub const boot_tanks_at: usize = 59;
pub const boot_health_at: usize = 60;
pub const boot_max_missiles_at: usize = 62;
pub const boot_missiles_at: usize = 64;
pub const boot_metroid_real_at: usize = 66;
pub const boot_metroid_displayed_at: usize = 67;
/// And the two cannon sheets `toggleMissiles` swaps in, beam then missile.
pub const boot_cannon_chr_at: usize = 68;
pub const cannon_sheets = [_][]const u8{ "gfx_cannonBeam", "gfx_cannonMissile" };
/// Version 12. The equipment bits, the parked beam and the selected weapon.
pub const boot_items_at: usize = 70;
pub const boot_beam_at: usize = 71;
pub const boot_weapon_at: usize = 72;
/// Version 13. The song a handover's Game Boy was playing, 0 for none.
pub const boot_song_at: usize = 73;
/// Version 14. `currentRoomSong` ($D092): the song the room asks for whenever
/// what is playing is not it, and the song a Metroid's death restores by adding
/// $11 to it. A save-file value, so a new game's comes from `initialSaveFile`
/// and a handover's is measured. **Not the same field as `boot_song_at`**,
/// which is what to play once at a handover; this is what the game keeps asking
/// for. Booting it as $FF -- "no door script has run" -- is what left a new
/// game silent and made the restore ask for $FF + $11 = $10, an id whose table
/// entry is code (`docs/bug_tracker.md`, 2026-09-22).
pub const boot_room_song_at: usize = 74;
/// Version 15. `acidDamageValue` and `spikeDamageValue` ($D077/$D078), what a
/// door's `DAMAGE` sets and a save carries. No version carried them before
/// Step 22, so a new game's acid took nothing off.
pub const boot_acid_at: usize = 75;
pub const boot_spike_at: usize = 76;
/// Version 16 (Step 24h). The `chr_obj` twin of `title_sheets[0]`, which the
/// title's copy to $8800 also puts under the Game Boy's objects.
pub const boot_title_obj_at: usize = 77;
/// Version 17 (1.0 Step 18b). `initialSaveFile`, the record a new game loads
/// its tables, solidity and graphics from, as the Game Boy's does. Left $FF for
/// a handover, which replays its door script instead.
pub const boot_save_at: usize = 78;
pub const boot_save_len: usize = screen.save_record_len;

/// One tile the record forces into `!TilemapBuf` after the room is drawn.
///
/// **This is the world a mid-run anchor needs and the map cannot describe.**
/// The original's collision is a lookup into its background tilemap, and
/// `destroyBlock` (01:56E9) writes $FF over the four tiles of every block the
/// reference shot out -- so a stretch anchored after a descent begins in a room
/// whose floor the converted map still has. See `engine/main.asm`'s `SeedWorld`.
pub const WorldSeed = screen.WorldSeed;

/// Entries `BootWorld` holds, mirrored from the engine's `!BOOT_WORLD_MAX`.
/// 168 is what fits between $00FC00 and the boot record at $00FE00 at three
/// bytes an entry, and it is 42 destroyed blocks.
pub const boot_world_max: usize = 168;
pub const boot_world_entry_bytes: usize = 3;

/// The four entries `title_loadGraphics` (05:42C7) copies as one $1000-byte run
/// to `vramDest_titleChr`. `bank_005.asm` says outright that the title screen
/// assumes they are contiguous, and `offsets.zig`'s own addresses agree: $A00 +
/// $300 + $200 + $100 is exactly the $1000 the copy moves, and $5F34 + $1000 is
/// exactly where `gfx_creditsSprTiles` begins.
pub const title_sheets = [boot_title_chr_count][]const u8{
    "gfx_titleScreen",
    "gfx_creditsFont",
    "gfx_itemFont",
    "gfx_creditsNumbers",
};
/// And the tilemap laid over them.
pub const title_map = "title_tilemap";

/// 1.0 Step 22. The sheets `prepareCredits` copies, as the engine's
/// `CreditsChr` holds their ids: the objects' two, then the background's four.
/// `CreditsChrRows` indexes this order.
pub const credits_sheets = [_]struct { kind: convert.AssetKind, name: []const u8 }{
    .{ .kind = .chr_obj, .name = "gfx_creditsSprTiles" },
    .{ .kind = .chr_obj, .name = "gfx_creditsNumbers" },
    .{ .kind = .chr_bg, .name = "gfx_creditsSprTiles" },
    .{ .kind = .chr_bg, .name = "gfx_creditsNumbers" },
    .{ .kind = .chr_bg, .name = "gfx_theEnd" },
    .{ .kind = .chr_bg, .name = "gfx_creditsFont" },
};

/// How many bytes `title_loadGraphics` moves, derived from the four entries
/// rather than written down as the $1000 the routine's `LD BC` says.
///
/// Null if they do not tile one gapless run in the listed order -- which is the
/// assumption `bank_005.asm` states in a comment ("the title screen assumes
/// these files are contiguous") and the only thing that makes a single copy of
/// four separate assets meaningful. A fifth entry, a moved one, or a reordered
/// list stops being a picture that is subtly wrong and becomes a build that
/// stops.
pub fn titleRunLen() ?usize {
    var expect: ?usize = null;
    var total: usize = 0;
    for (title_sheets) |name| {
        const e = offsets_table.find(name) orelse return null;
        if (expect) |at| {
            if (e.romOffset() != at) return null;
        }
        expect = e.romEnd();
        total += e.size;
    }
    return total;
}
/// The `offsets.zig` entry whose converted `chr_obj` asset Samus is drawn from.
/// `loadGame_loadGraphics` (00:05FD) copies it to `vramDest_samus`, which is
/// $8000, so its Game Boy tile ids are its object character indexes unchanged.
pub const samus_sheet = "gfx_samusPowerSuit";
/// One u24 per `screens.tiletable_order` slot, into the contiguous metatile
/// region.
pub const tile_table_count: usize = screens.tiletable_order.len;
pub const tile_table_bytes: usize = tile_table_count * 3;

comptime {
    // The directory entry size is declared in `layout` because the region that
    // holds the directory is reserved there. If the two ever disagree the
    // directory would overrun its region, so they are the same constant.
    std.debug.assert(directory_entry_bytes == 8);
}

// ---- Addresses --------------------------------------------------------------

pub const AddrError = error{OutsideCart};

/// LoROM: file offset -> SNES address. Bank `n` presents its 32 KiB at $8000.
pub fn snesAddr(off: usize) u32 {
    const bank: u32 = @intCast(off / layout.bank_size);
    const addr: u32 = @intCast(0x8000 + off % layout.bank_size);
    return (bank << 16) | addr;
}

/// SNES address -> file offset. The $80-$FF mirror maps to the same bytes, so
/// the high bit is dropped rather than refused.
pub fn fileOffset(snes: u32) AddrError!usize {
    const bank: usize = (snes >> 16) & 0x7F;
    const addr: usize = snes & 0xFFFF;
    if (addr < 0x8000) return AddrError.OutsideCart;
    const off = bank * layout.bank_size + (addr - 0x8000);
    if (off >= layout.romSize()) return AddrError.OutsideCart;
    return off;
}

/// Look a label up in the committed wla-format symbol file.
///
/// The symbol file is parsed rather than the addresses being written down here
/// because a hand-copied address is a second source of truth: reassembling the
/// engine moves `RegionTable`, and a constant in this file would not move with
/// it. The `[addr-to-line mapping]` section has the same line shape, so the
/// section header is tracked rather than the line matched loosely.
pub fn symbol(name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, symbols, '\n');
    var in_labels = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        if (line[0] == '[') {
            in_labels = std.mem.eql(u8, line, "[labels]");
            continue;
        }
        if (!in_labels) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, line[sp + 1 ..], name)) continue;
        const colon = std.mem.indexOfScalar(u8, line[0..sp], ':') orelse continue;
        const bank = std.fmt.parseInt(u8, line[0..colon], 16) catch continue;
        const addr = std.fmt.parseInt(u16, line[colon + 1 .. sp], 16) catch continue;
        return (@as(u32, bank) << 16) | addr;
    }
    return null;
}

/// A label's offset into the engine image.
pub fn symbolOffset(name: []const u8) ?usize {
    const snes = symbol(name) orelse return null;
    const off = fileOffset(snes) catch return null;
    if (off >= image.len) return null;
    return off;
}

// ---- Result ----------------------------------------------------------------

pub const Placement = struct {
    class: layout.Class,
    name: []const u8,
    /// What the converted stream calls this blob. For the three asset classes
    /// it is the asset id a `COPY` operand carries; elsewhere it is the blob's
    /// ordinal within its class, which is what a map bank or a tileset slot is
    /// indexed by anyway.
    id: u8,
    offset: usize,
    len: usize,

    pub fn addr(self: Placement) u32 {
        return snesAddr(self.offset);
    }
};

pub const Rom = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    placements: []Placement,
    /// Index of the first placement of each class, plus a final sentinel.
    class_start: [layout.class_count + 1]usize,

    pub fn deinit(self: *Rom) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.placements);
    }

    pub fn digest(self: Rom) [32]u8 {
        var out: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.bytes, &out, .{});
        return out;
    }

    pub fn of(self: Rom, class: layout.Class) []const Placement {
        const i: usize = @intFromEnum(class);
        return self.placements[self.class_start[i]..self.class_start[i + 1]];
    }
};

// ---- Failure ---------------------------------------------------------------

pub const Error = error{
    /// The engine image no longer fits the space reserved for it.
    EngineTooLarge,
    /// `RegionTable` is not in the symbol file, or not inside the image.
    PatchTableMissing,
    /// The table's magic, version, class count, or entry size disagrees with
    /// this file. Refusing beats patching an image built to a different shape.
    PatchTableMismatch,
    /// A class's blobs do not fit its reserved region.
    RegionOverflow,
    /// A single blob is larger than one bank, so no placement can satisfy the
    /// DMA controller's non-incrementing bank register.
    BlobExceedsBank,
    /// The converted set has no `chr_obj` asset for Samus's sheet, so nothing
    /// would put her characters in VRAM and she would be drawn out of whatever
    /// the object region happened to hold.
    SamusSheetMissing,
    OutOfMemory,
};

/// Why the build failed, in a sentence, plus the class in machine-readable
/// form. Both, because the caller that prints the message and the test that
/// asserts which class overflowed should not have to agree on wording.
pub const Diagnosis = struct {
    buf: [256]u8 = undefined,
    message: []const u8 = "",
    class: ?layout.Class = null,

    fn fail(self: *Diagnosis, class: ?layout.Class, comptime fmt: []const u8, args: anytype) void {
        self.class = class;
        self.message = std.fmt.bufPrint(&self.buf, fmt, args) catch "diagnosis did not fit";
    }
};

// ---- Building --------------------------------------------------------------

const Source = struct {
    class: layout.Class,
    name: []const u8,
    id: u8,
    bytes: []const u8,
};

fn collect(gpa: std.mem.Allocator, set: convert.Set) !std.ArrayList(Source) {
    var list: std.ArrayList(Source) = .empty;
    errdefer list.deinit(gpa);

    // Class order is enum order, and within a class the converter's own order.
    // `layout.measure` walks the same sequence, so the padding it charged for
    // is the padding this produces.
    inline for (.{
        .{ layout.Class.chr_bg, convert.AssetKind.chr_bg },
        .{ layout.Class.chr_obj, convert.AssetKind.chr_obj },
        .{ layout.Class.tilemap, convert.AssetKind.tilemap },
    }) |pair| {
        const class, const kind = pair;
        for (set.assets) |a| {
            if (a.kind != kind) continue;
            try list.append(gpa, .{ .class = class, .name = a.name, .id = a.id, .bytes = a.bytes });
        }
    }

    try appendBlobs(gpa, &list, .metatiles, set.metatiles);
    try appendBlobs(gpa, &list, .collision, set.collision);
    try appendBlobs(gpa, &list, .solidity, &.{set.solidity});
    try appendBlobs(gpa, &list, .map_cells, set.map_cells);
    try appendBlobs(gpa, &list, .map_screens, set.map_screens);
    try appendBlobs(gpa, &list, .doors, &.{ set.doors, set.load_sources });
    try appendBlobs(gpa, &list, .door_pointers, &.{set.door_pointers});

    // The directory describes every blob including itself, so its own entry is
    // written after every address is known - but it does not have to be *placed*
    // last, and `physics` follows it for the reason `snes_layout.Class` gives.
    try list.append(gpa, .{
        .class = .directory,
        .name = "directory",
        .id = 0,
        .bytes = &.{},
    });
    try appendBlobs(gpa, &list, .physics, set.physics);
    try appendBlobs(gpa, &list, .metasprites, set.metasprites);
    try appendBlobs(gpa, &list, .enemies, set.enemies);
    try appendBlobs(gpa, &list, .aram, set.aram);
    try appendBlobs(gpa, &list, .title_art, set.title_art);
    try appendBlobs(gpa, &list, .debug, set.debug);
    return list;
}

fn appendBlobs(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Source),
    class: layout.Class,
    blobs: []const convert.Blob,
) !void {
    for (blobs, 0..) |b, i| {
        try list.append(gpa, .{ .class = class, .name = b.name, .id = @intCast(i & 0xFF), .bytes = b.bytes });
    }
}

pub fn build(gpa: std.mem.Allocator, set: convert.Set, boot: screen.Boot, diag: *Diagnosis) Error!Rom {
    var sources = collect(gpa, set) catch return Error.OutOfMemory;
    defer sources.deinit(gpa);

    const placements = gpa.alloc(Placement, sources.items.len) catch return Error.OutOfMemory;
    errdefer gpa.free(placements);

    const bytes = gpa.alloc(u8, layout.romSize()) catch return Error.OutOfMemory;
    errdefer gpa.free(bytes);
    @memset(bytes, 0);

    if (image.len > layout.engine_reserved) {
        diag.fail(null, "engine image is {d} bytes, {d} more than the {d} reserved for it", .{
            image.len, image.len - layout.engine_reserved, layout.engine_reserved,
        });
        return Error.EngineTooLarge;
    }
    @memcpy(bytes[0..image.len], image);

    // ---- Place, class by class ---------------------------------------------
    var class_start: [layout.class_count + 1]usize = undefined;
    var sizes: [layout.max_blobs]usize = undefined;
    var offsets: [layout.max_blobs]usize = undefined;
    const dir_bytes = layout.directoryBytes(set);

    var cursor: usize = 0;
    for (std.enums.values(layout.Class)) |class| {
        class_start[@intFromEnum(class)] = cursor;
        const first = cursor;
        var n: usize = 0;
        while (cursor < sources.items.len and sources.items[cursor].class == class) : (cursor += 1) {
            const src = sources.items[cursor];
            const len = if (class == .directory) dir_bytes else src.bytes.len;
            if (n >= layout.max_blobs) {
                diag.fail(class, "{s} has more than {d} blobs", .{ class.label(), layout.max_blobs });
                return Error.RegionOverflow;
            }
            if (len > layout.bank_size) {
                diag.fail(class, "{s} blob \"{s}\" is {d} bytes, larger than one {d}-byte bank", .{
                    class.label(), src.name, len, layout.bank_size,
                });
                return Error.BlobExceedsBank;
            }
            sizes[n] = len;
            n += 1;
        }

        const start = layout.regionStart(class);
        const used = layout.placeClass(class, start, sizes[0..n], offsets[0..n]);
        const reserve = layout.reserved[@intFromEnum(class)];
        if (used > reserve) {
            diag.fail(class, "{s} needs {d} bytes but only {d} are reserved: {d} over", .{
                class.label(), used, reserve, used - reserve,
            });
            return Error.RegionOverflow;
        }

        for (0..n) |i| {
            const src = sources.items[first + i];
            placements[first + i] = .{
                .class = class,
                .name = src.name,
                .id = src.id,
                .offset = offsets[i],
                .len = sizes[i],
            };
            if (class != .directory) @memcpy(bytes[offsets[i]..][0..sizes[i]], src.bytes);
        }
    }
    class_start[layout.class_count] = cursor;

    var rom: Rom = .{
        .allocator = gpa,
        .bytes = bytes,
        .placements = placements,
        .class_start = class_start,
    };

    writeDirectory(&rom);
    try patchTable(&rom, diag);
    try patchBoot(&rom, set, boot, diag);
    patchHeader(&rom);
    return rom;
}

/// One entry per blob, in placement order: u24 address, u8 id, u16 length, and
/// two reserved bytes that keep the entry a power of two so the engine indexes
/// with a shift rather than a multiply.
fn writeDirectory(rom: *Rom) void {
    const dir = rom.of(.directory)[0];
    const w = rom.bytes[dir.offset..][0..dir.len];
    for (rom.placements, 0..) |p, i| {
        const e = w[i * directory_entry_bytes ..][0..directory_entry_bytes];
        const a = p.addr();
        e[0] = @intCast(a & 0xFF);
        e[1] = @intCast((a >> 8) & 0xFF);
        e[2] = @intCast((a >> 16) & 0xFF);
        e[3] = p.id;
        std.mem.writeInt(u16, e[4..6], @intCast(p.len), .little);
        e[6] = 0;
        e[7] = 0;
    }
}

fn patchTable(rom: *Rom, diag: *Diagnosis) Error!void {
    const table = symbolOffset("RegionTable") orelse {
        diag.fail(null, "the engine image has no RegionTable symbol", .{});
        return Error.PatchTableMissing;
    };
    const head = rom.bytes[table..][0..8];
    if (!std.mem.eql(u8, head[0..4], patch_magic)) {
        diag.fail(null, "RegionTable magic is ${X:0>2}{X:0>2}{X:0>2}{X:0>2}, not \"{s}\"", .{ head[0], head[1], head[2], head[3], patch_magic });
        return Error.PatchTableMismatch;
    }
    if (head[4] != patch_version or head[5] != layout.class_count or head[6] != region_entry_bytes) {
        diag.fail(null, "RegionTable is version {d}, {d} classes, {d}-byte entries; the manifest is version {d}, {d} classes, {d}-byte entries", .{
            head[4],         head[5],             head[6],
            patch_version,   layout.class_count,  region_entry_bytes,
        });
        return Error.PatchTableMismatch;
    }

    const dir = rom.of(.directory)[0];
    const entries = table + 8;
    for (std.enums.values(layout.Class)) |class| {
        const i: usize = @intFromEnum(class);
        const e = rom.bytes[entries + i * region_entry_bytes ..][0..region_entry_bytes];
        writeAddr(e[0..3], snesAddr(layout.regionStart(class)));
        writeAddr(e[3..6], snesAddr(dir.offset + rom.class_start[i] * directory_entry_bytes));
        std.mem.writeInt(u16, e[6..8], @intCast(rom.class_start[i + 1] - rom.class_start[i]), .little);
    }
}

fn writeAddr(dst: *[3]u8, a: u32) void {
    dst[0] = @intCast(a & 0xFF);
    dst[1] = @intCast((a >> 8) & 0xFF);
    dst[2] = @intCast((a >> 16) & 0xFF);
}

/// The boot record and the metatile table's address list.
///
/// The table list is where the contiguous-run rule in `snes_layout` is cashed
/// in: a `TILETABLE` operand selects a *base* within one region, and a screen is
/// allowed to index off the end of the table that base names into the next one.
/// So the run is checked for contiguity here rather than assumed - if the
/// placement rule ever changed underneath, the symptom would be a screen drawn
/// out of the wrong table, which is not a symptom anyone would trace back to
/// packing.
fn patchBoot(rom: *Rom, set: convert.Set, boot: screen.Boot, diag: *Diagnosis) Error!void {
    const at = symbolOffset("BootRecord") orelse {
        diag.fail(null, "the engine image has no BootRecord symbol", .{});
        return Error.PatchTableMissing;
    };
    const head = rom.bytes[at..][0..5];
    if (!std.mem.eql(u8, head[0..4], boot_magic)) {
        diag.fail(null, "BootRecord magic is ${X:0>2}{X:0>2}{X:0>2}{X:0>2}, not \"{s}\"", .{
            head[0], head[1], head[2], head[3], boot_magic,
        });
        return Error.PatchTableMismatch;
    }
    if (head[4] != boot_version) {
        diag.fail(null, "BootRecord is version {d}; the builder writes version {d}", .{ head[4], boot_version });
        return Error.PatchTableMismatch;
    }

    rom.bytes[at + 5] = boot.map_index;
    rom.bytes[at + 6] = boot.cell;
    rom.bytes[at + 7] = boot.tiletable;
    std.mem.writeInt(u16, rom.bytes[at + 8 ..][0..2], boot.door_index, .little);
    for (boot.palette, 0..) |colour, i| {
        std.mem.writeInt(u16, rom.bytes[at + 10 + i * 2 ..][0..2], colour, .little);
    }

    // Samus's sheet is named here rather than in `chooseBoot`, because the id
    // is the converter's: `chooseBoot` picks a screen out of the ROM before
    // anything has been converted, and an id it invented would be a second
    // source of truth for the one the asset table already assigns.
    const sheet = blk: {
        for (set.assets) |a| {
            if (a.kind == .chr_obj and std.mem.eql(u8, a.name, samus_sheet)) break :blk a;
        }
        diag.fail(.chr_obj, "the set has no chr_obj asset \"{s}\"; nothing would upload Samus", .{samus_sheet});
        return Error.SamusSheetMissing;
    };
    rom.bytes[at + boot_samus_chr_at] = sheet.id;
    for (boot.obj_palette, 0..) |colour, i| {
        std.mem.writeInt(u16, rom.bytes[at + boot_obj_palette_at + i * 2 ..][0..2], colour, .little);
    }

    // Version 3. The engine used to compute the middle of the boot cell for
    // itself; `chooseBoot` computes it now, so this is a copy rather than a
    // decision, and a caller that wants Samus somewhere else changes the `Boot`
    // rather than the engine.
    std.mem.writeInt(u16, rom.bytes[at + boot_samus_y_at ..][0..2], boot.samus_y, .little);
    std.mem.writeInt(u16, rom.bytes[at + boot_samus_x_at ..][0..2], boot.samus_x, .little);
    rom.bytes[at + boot_pose_at] = boot.pose;
    rom.bytes[at + boot_facing_at] = boot.facing;
    std.mem.writeInt(u16, rom.bytes[at + boot_input_at ..][0..2], boot.input, .little);

    // Version 4. `InitState` used to seed the camera from the position two
    // lines up; the residue audit measured the game's camera at a handover and
    // found it somewhere else entirely, so it is its own pair of fields now.
    std.mem.writeInt(u16, rom.bytes[at + boot_cam_y_at ..][0..2], boot.cam_y, .little);
    std.mem.writeInt(u16, rom.bytes[at + boot_cam_x_at ..][0..2], boot.cam_x, .little);

    // Version 5. The counter's phase decides the walk speed on every frame, so
    // a counter that starts from the cart's own reset makes the port's walk
    // agree with the game's only by accident. `Boot.frame_count` carries what
    // the seed must be; see there for the offset between it and the $FF97 the
    // movie measured.
    std.mem.writeInt(u16, rom.bytes[at + boot_frame_count_at ..][0..2], boot.frame_count, .little);

    // Version 8. The appearance sequence is a *wait* on a counter and not a
    // fixed number of frames in a handler, so the counter has to be seeded or
    // the pose hands over on its first frame. Zero everywhere else, which is
    // what the original holds at every point a graded stretch is anchored.
    std.mem.writeInt(u16, rom.bytes[at + boot_countdown_at ..][0..2], boot.countdown, .little);
    rom.bytes[at + boot_mode_at] = @intFromEnum(boot.mode);

    // Version 9. The title screen, as five asset ids: the engine lays the four
    // character blobs down from character zero in this order and then draws the
    // tilemap over them. The order is load-bearing -- it is the order the Game
    // Boy's single copy walks, which is what `target.charForTitleId`'s rotation
    // is a rotation *by* -- so the ids are resolved by name here rather than
    // taken in whatever order the asset list happens to hold them.
    if (titleRunLen() == null) {
        diag.fail(.chr_bg, "the four title-screen sheets are not one gapless run; the copy they model is one block", .{});
        return Error.PatchTableMismatch;
    }
    for (title_sheets, 0..) |name, i| {
        const tile_sheet = blk: {
            for (set.assets) |a| {
                if (a.kind == .chr_bg and std.mem.eql(u8, a.name, name)) break :blk a;
            }
            diag.fail(.chr_bg, "the set has no chr_bg asset \"{s}\"; the title screen would draw garbage", .{name});
            return Error.SamusSheetMissing;
        };
        rom.bytes[at + boot_title_chr_at + i] = tile_sheet.id;
    }
    rom.bytes[at + boot_title_map_at] = blk: {
        for (set.assets) |a| {
            if (a.kind == .tilemap and std.mem.eql(u8, a.name, title_map)) break :blk a.id;
        }
        diag.fail(.tilemap, "the set has no tilemap asset \"{s}\"; there is no title screen to draw", .{title_map});
        return Error.SamusSheetMissing;
    };

    // Version 10. The tiles the record forces into `!TilemapBuf` after the room
    // is drawn -- the blocks the reference shot out, which the converted map
    // still has. Written even when empty, because the field is $FFFF in an
    // unpatched image and `SeedWorld` would walk 65 535 entries of it.
    if (boot.world.len > boot_world_max) {
        diag.fail(null, "the record forces {d} tiles into the world; BootWorld holds {d}", .{
            boot.world.len, boot_world_max,
        });
        return Error.PatchTableMismatch;
    }
    std.mem.writeInt(u16, rom.bytes[at + boot_world_count_at ..][0..2], @intCast(boot.world.len), .little);

    // Version 11. What she is carrying, which no earlier version did -- so
    // every cart started with zero health and zero missiles.
    rom.bytes[at + boot_tanks_at] = boot.loadout.tanks;
    std.mem.writeInt(u16, rom.bytes[at + boot_health_at ..][0..2], boot.loadout.health, .little);
    std.mem.writeInt(u16, rom.bytes[at + boot_max_missiles_at ..][0..2], boot.loadout.max_missiles, .little);
    std.mem.writeInt(u16, rom.bytes[at + boot_missiles_at ..][0..2], boot.loadout.missiles, .little);
    rom.bytes[at + boot_metroid_real_at] = boot.loadout.metroid_real;
    rom.bytes[at + boot_metroid_displayed_at] = boot.loadout.metroid_displayed;
    // Version 12. What she has equipped: a handover taken with missiles
    // selected used to boot with the beam.
    rom.bytes[at + boot_items_at] = boot.loadout.items;
    rom.bytes[at + boot_beam_at] = boot.loadout.beam;
    rom.bytes[at + boot_weapon_at] = boot.loadout.active_weapon;
    // Version 13. What the engine was playing: a handover used to boot silent.
    rom.bytes[at + boot_song_at] = boot.loadout.song;
    // Version 14. What the room asks for, and what a Metroid's death restores.
    rom.bytes[at + boot_room_song_at] = boot.loadout.room_song;
    // Version 15. The damage a room does: acid took nothing off without it.
    rom.bytes[at + boot_acid_at] = boot.loadout.acid_damage;
    rom.bytes[at + boot_spike_at] = boot.loadout.spike_damage;

    // Version 16. The title's first sheet as objects, for its menu.
    rom.bytes[at + boot_title_obj_at] = blk: {
        for (set.assets) |a| {
            if (a.kind == .chr_obj and std.mem.eql(u8, a.name, title_sheets[0])) break :blk a.id;
        }
        diag.fail(.chr_obj, "the set has no chr_obj asset \"{s}\"; the title's menu would draw garbage", .{title_sheets[0]});
        return Error.SamusSheetMissing;
    };
    // Version 17. The new game's save record.
    if (boot.save) |sv| @memcpy(rom.bytes[at + boot_save_at ..][0..boot_save_len], &sv);
    // 1.0 Step 8a: `loadGraphics`' records, by sheet name for the reason
    // Samus's is: the ids are the converter's. The cannon's two are the first
    // two rows, which `BootCannonChr` held until then.
    {
        const table = set.gfx_info orelse {
            diag.fail(null, "the set carries no gfxInfo records; `loadGraphics` would upload nothing", .{});
            return Error.PatchTableMissing;
        };
        const gi = symbolOffset("GfxInfo") orelse {
            diag.fail(null, "the engine image has no GfxInfo symbol", .{});
            return Error.PatchTableMissing;
        };
        const Ids = struct {
            set: convert.Set,
            pub fn of(self: @This(), name: []const u8) !u8 {
                for (self.set.assets) |a| {
                    if (a.kind == .chr_obj and std.mem.eql(u8, a.name, name)) return a.id;
                }
                return Error.SamusSheetMissing;
            }
        };
        const bytes = gfx_info.tableBytes(table, Ids{ .set = set }) catch {
            diag.fail(.chr_obj, "a gfxInfo record's sheet is not a chr_obj asset", .{});
            return Error.SamusSheetMissing;
        };
        @memcpy(rom.bytes[gi..][0..bytes.len], &bytes);
    }
    // 1.0 Step 22: the credits' six sheets, in `CreditsChr`'s order.
    {
        const cc = symbolOffset("CreditsChr") orelse {
            diag.fail(null, "the engine image has no CreditsChr symbol", .{});
            return Error.PatchTableMissing;
        };
        for (credits_sheets, 0..) |want, i| {
            rom.bytes[cc + i] = blk: {
                for (set.assets) |a| {
                    if (a.kind == want.kind and std.mem.eql(u8, a.name, want.name)) break :blk a.id;
                }
                diag.fail(if (want.kind == .chr_obj) .chr_obj else .chr_bg, "the set has no {s} asset \"{s}\"; the credits would draw garbage", .{ @tagName(want.kind), want.name });
                return Error.SamusSheetMissing;
            };
        }
    }
    const world = symbolOffset("BootWorld") orelse {
        diag.fail(null, "the engine image has no BootWorld symbol", .{});
        return Error.PatchTableMissing;
    };
    for (boot.world, 0..) |seed, i| {
        const e = world + i * boot_world_entry_bytes;
        std.mem.writeInt(u16, rom.bytes[e..][0..2], seed.index, .little);
        rom.bytes[e + 2] = seed.tile;
    }

    const list = symbolOffset("TileTableBases") orelse {
        diag.fail(null, "the engine image has no TileTableBases symbol", .{});
        return Error.PatchTableMissing;
    };
    const run = rom.of(.metatiles);
    if (run.len != tile_table_count) {
        diag.fail(.metatiles, "the set has {d} metatile tables; the engine has room for {d}", .{
            run.len, tile_table_count,
        });
        return Error.PatchTableMismatch;
    }
    var expect = run[0].offset;
    for (run) |p| {
        if (p.offset != expect) {
            diag.fail(.metatiles, "metatile table \"{s}\" is at ${X:0>6}, not the ${X:0>6} the run continues at", .{
                p.name, snesAddr(p.offset), snesAddr(expect),
            });
            return Error.RegionOverflow;
        }
        expect += p.len;
    }
    if (run[0].offset / layout.bank_size != (expect - 1) / layout.bank_size) {
        diag.fail(.metatiles, "the metatile run spans two banks: ${X:0>6} to ${X:0>6}", .{
            snesAddr(run[0].offset), snesAddr(expect - 1),
        });
        return Error.RegionOverflow;
    }

    const bases = render.tableBases(set) catch {
        diag.fail(.metatiles, "the metatile tables are not the {d} that screens.tiletable_order names", .{tile_table_count});
        return Error.PatchTableMismatch;
    };
    for (bases, 0..) |base, i| {
        writeAddr(rom.bytes[list + i * 3 ..][0..3], snesAddr(run[0].offset + base));
    }
}

/// The two header fields the engine cannot know: how big the finished cart is,
/// and its checksum. Both are patched rather than assembled, which is why
/// `tools/build-engine.sh` passes `--fix-checksum=off` - a checksum over the
/// engine image alone would be wrong for the ROM it ends up in.
/// The `--debug` build (1.0 Step 2b, C8): `DebugAllowed` to 1, so the title's
/// L+R+Start can set `debugFlag`, and the checksum made again. That byte and
/// the checksum's four are the whole difference from the retail cart.
pub fn enableDebug(rom: *Rom) error{MissingSymbol}!void {
    const at = symbolOffset("DebugAllowed") orelse return error.MissingSymbol;
    rom.bytes[at] = 1;
    patchHeader(rom);
}

fn patchHeader(rom: *Rom) void {
    if (symbolOffset("RomSizeByte")) |off| {
        rom.bytes[off] = @intCast(std.math.log2_int(usize, layout.romSize() / 1024));
    }
    const complement = symbolOffset("ChecksumComplement");
    const checksum = symbolOffset("Checksum");
    if (complement == null or checksum == null) return;
    // The convention: the fields read $FFFF and $0000 while the sum is taken.
    std.mem.writeInt(u16, rom.bytes[complement.?..][0..2], 0xFFFF, .little);
    std.mem.writeInt(u16, rom.bytes[checksum.?..][0..2], 0x0000, .little);
    var sum: u16 = 0;
    for (rom.bytes) |b| sum +%= b;
    std.mem.writeInt(u16, rom.bytes[checksum.?..][0..2], sum, .little);
    std.mem.writeInt(u16, rom.bytes[complement.?..][0..2], ~sum, .little);
}

// ---- Output ----------------------------------------------------------------

/// A wla-format symbol file for the finished ROM: the engine's own labels, then
/// one label per placed blob. Mesen2 loads this directly, and Step 14's address
/// correspondence map is generated against it rather than against a copy, so a
/// moved symbol cannot silently drift.
pub fn writeSymbols(rom: Rom, out: *std.Io.Writer) !void {
    try out.print("; wla symbolic information file\n; generated by m2snes\n\n[labels]\n", .{});
    var lines = std.mem.splitScalar(u8, symbols, '\n');
    var in_labels = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        if (line[0] == '[') {
            in_labels = std.mem.eql(u8, line, "[labels]");
            continue;
        }
        if (in_labels) try out.print("{s}\n", .{line});
    }
    for (rom.placements) |p| {
        const a = p.addr();
        try out.print("{X:0>2}:{X:0>4} {s}_{s}\n", .{ a >> 16, a & 0xFFFF, p.class.label(), p.name });
    }
}

pub fn print(rom: Rom, out: *std.Io.Writer) !void {
    try out.print("engine {d} bytes of {d} reserved, cart {d} KiB, {d} blobs placed\n\n", .{
        image.len, layout.engine_reserved, layout.romSize() / 1024, rom.placements.len,
    });
    try out.print("{s:<14} {s:>6} {s:>10} {s:>10}  {s}\n", .{ "class", "blobs", "first", "bytes", "largest blob" });
    for (std.enums.values(layout.Class)) |class| {
        const ps = rom.of(class);
        var total: usize = 0;
        var largest: usize = 0;
        var largest_name: []const u8 = "-";
        for (ps) |p| {
            total += p.len;
            if (p.len > largest) {
                largest = p.len;
                largest_name = p.name;
            }
        }
        const first: u32 = if (ps.len != 0) ps[0].addr() else 0;
        try out.print("{s:<14} {d:>6}   ${X:0>2}:{X:0>4} {d:>10}  {s} ({d})\n", .{
            class.label(), ps.len, first >> 16, first & 0xFFFF, total, largest_name, largest,
        });
    }
    try out.print("\nsha256 {x}\n", .{&rom.digest()});
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the committed engine image is a well-formed LoROM cart" {
    try testing.expect(image.len <= layout.engine_reserved);
    try testing.expect(image.len % layout.bank_size == 0);

    // The header, at the LoROM position the map-mode byte claims.
    const header = symbolOffset("CartHeader").?;
    try testing.expectEqual(@as(usize, 0x7FC0), header);
    try testing.expectEqualStrings("SUPER RETURN OF SAMUS", image[header..][0..21]);
    try testing.expectEqual(@as(u8, 0x20), image[header + 21]); // LoROM, slow

    // The emulation-mode reset vector, which is the only entry point a SNES
    // uses, has to point at code inside bank $00.
    const reset = std.mem.readInt(u16, image[0x7FFC..][0..2], .little);
    try testing.expectEqual(symbol("Reset").? & 0xFFFF, reset);
    try testing.expect(reset >= 0x8000);
    // And the native NMI vector at the routine that acknowledges $4210.
    const nmi = std.mem.readInt(u16, image[0x7FEA..][0..2], .little);
    try testing.expectEqual(symbol("NMI").? & 0xFFFF, nmi);
}

test "the unpatched patch table announces what it expects" {
    const table = symbolOffset("RegionTable").?;
    try testing.expectEqualStrings(patch_magic, image[table..][0..4]);
    try testing.expectEqual(patch_version, image[table + 4]);
    try testing.expectEqual(@as(u8, layout.class_count), image[table + 5]);
    try testing.expectEqual(@as(u8, region_entry_bytes), image[table + 6]);
    // Every entry is $FF: an unpatched image points at an address no 512 KiB
    // cart has, so running one faults instead of reading bank 0 by accident.
    const entries = image[table + 8 ..][0 .. layout.class_count * region_entry_bytes];
    for (entries) |b| try testing.expectEqual(@as(u8, 0xFF), b);
}

/// Find a register's value in the engine's PPU setup table. The table is a list
/// of (register low byte, value) pairs terminated by a zero register, and later
/// entries win, which is what the engine's own loop does.
fn setupValue(reg: u16) ?u8 {
    const start = symbolOffset("PpuSetup") orelse return null;
    var found: ?u8 = null;
    var i = start;
    while (image[i] != 0) : (i += 2) {
        if (image[i] == (reg & 0xFF)) found = image[i + 1];
    }
    return found;
}

test "the engine's video decisions are the ones snes_target made" {
    // Mode 1, play field on BG3. `snes_target.bg_mode` is the decision; this is
    // the assembler agreeing with it.
    try testing.expectEqual(@as(u8, target.bg_mode), setupValue(0x2105).?);

    // Tilemap and character bases, in the granularity each register takes.
    try testing.expectEqual(@as(u8, (target.bg3_map_base >> 10) << 2), setupValue(0x2109).?);
    try testing.expectEqual(@as(u8, (target.bg2_map_base >> 10) << 2), setupValue(0x2108).?);
    try testing.expectEqual(@as(u8, target.bg3_char_base >> 12), setupValue(0x210C).? & 0x0F);
    try testing.expectEqual(@as(u8, target.bg12_char_base >> 12), setupValue(0x210B).? & 0x0F);
    try testing.expectEqual(@as(u8, target.bg2_char_base >> 12), setupValue(0x210B).? >> 4);
    try testing.expectEqual(@as(u8, target.obj_char_base >> 13), setupValue(0x2101).? & 0x07);

    // The main screen draws BG2, BG3 and OBJ; BG1 is reserved for the wider
    // view and must stay off, or Phase 0a would render a layer nothing fills.
    const tm = setupValue(0x212C).?;
    try testing.expectEqual(@as(u8, 0), tm & 0x01);
    try testing.expect(tm & 0x02 != 0);
    try testing.expect(tm & 0x04 != 0);
    try testing.expect(tm & 0x10 != 0);
    // The window masks exactly the layers the main screen draws.
    try testing.expectEqual(tm, setupValue(0x212E).?);

    // The play window, horizontally: centred and `view_w` wide.
    const left = setupValue(0x2126).?;
    const right = setupValue(0x2127).?;
    try testing.expectEqual(@as(u8, (target.screen_w - target.view_w) / 2), left);
    try testing.expectEqual(@as(u16, target.view_w), @as(u16, right) - left + 1);
    // Window 1 enabled and inverted for each layer the main screen draws, so
    // the mask is the area *outside* the window.
    try testing.expectEqual(@as(u8, 0x33), setupValue(0x2123).?);
    try testing.expectEqual(@as(u8, 0x03), setupValue(0x2124).? & 0x0F);
    try testing.expectEqual(@as(u8, 0x03), setupValue(0x2125).? & 0x0F);
}

test "the play window is view_h lines out of a screen_h frame" {
    const start = symbolOffset("WindowBands").?;
    var i = start;
    var lines: u16 = 0;
    var visible: u16 = 0;
    while (image[i] != 0) : (i += 2) {
        const count = image[i];
        // Seven bits, not eight. Bit 7 selects HDMA's repeat mode, where the
        // channel reads a fresh byte every line rather than holding one - so a
        // count of 144 is not a 144-line band, it is "repeat for 16" followed
        // by the rest of this table being read as per-line data. This test
        // summed the bytes and passed while exactly that was happening, which
        // is why it now looks at the bit instead of the total.
        try testing.expect(count < 0x80);
        try testing.expect(count > 0);
        lines += count;
        if (image[i + 1] != 0) visible += count;
    }
    try testing.expectEqual(@as(u16, target.screen_h), lines);
    try testing.expectEqual(@as(u16, target.view_h), visible);
    // Centred: the first band is the top margin.
    try testing.expectEqual(@as(u8, (target.screen_h - target.view_h) / 2), image[start]);
}

test "LoROM addresses round-trip" {
    try testing.expectEqual(@as(u32, 0x008000), snesAddr(0));
    try testing.expectEqual(@as(u32, 0x00FFFF), snesAddr(layout.bank_size - 1));
    try testing.expectEqual(@as(u32, 0x018000), snesAddr(layout.bank_size));
    var off: usize = 0;
    while (off < layout.romSize()) : (off += 0x1234) {
        try testing.expectEqual(off, try fileOffset(snesAddr(off)));
    }
    // The $80 mirror is the same bytes.
    try testing.expectEqual(@as(usize, 0), try fileOffset(0x808000));
    try testing.expectError(AddrError.OutsideCart, fileOffset(0x007FFF));
    try testing.expectError(AddrError.OutsideCart, fileOffset(0x408000));
}

test "an oversized class is refused, and the error names it" {
    // A hand-built set, not the ROM: the point is that the failure path is
    // exercised at all, and the real set is (correctly) nowhere near a region
    // boundary. `map_screens` is the tightest class, so it is the one a real
    // overflow would hit first.
    const gpa = testing.allocator;
    const reserve = layout.reserved[@intFromEnum(layout.Class.map_screens)];
    const blob_len = layout.bank_size;
    const count = reserve / blob_len + 1;

    const backing = try gpa.alloc(u8, blob_len);
    defer gpa.free(backing);
    @memset(backing, 0xA5);

    const blobs = try gpa.alloc(convert.Blob, count);
    defer gpa.free(blobs);
    for (blobs) |*b| b.* = .{ .name = "oversized", .bytes = backing };

    var set: convert.Set = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .assets = &.{},
        .metatiles = &.{},
        .collision = &.{},
        .solidity = .{ .name = "solidity", .bytes = &.{} },
        .map_cells = &.{},
        .map_screens = blobs,
        .doors = .{ .name = "doors", .bytes = &.{} },
        .door_pointers = .{ .name = "door_pointers", .bytes = &.{} },
        .load_sources = .{ .name = "load_sources", .bytes = &.{} },
        .physics = &.{},
        .metasprites = &.{},
        .enemies = &.{},
        .aram = &.{},
        .by_basis = .{ 0, 0, 0 },
    };
    defer set.deinit();

    var diag: Diagnosis = .{};
    try testing.expectError(Error.RegionOverflow, build(gpa, set, testBoot, &diag));
    // Named twice over: as a class the caller can switch on, and in a message a
    // human reads. A build error that says only "does not fit" would send
    // someone to the wrong region.
    try testing.expectEqual(layout.Class.map_screens, diag.class.?);
    try testing.expect(std.mem.indexOf(u8, diag.message, "map_screens") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "over") != null);
    // And the layout validator agrees, which is the check that the two halves
    // are measuring the same thing.
    try testing.expect(!layout.measure(set).fits());
}

test "a blob larger than one bank is refused by name" {
    const gpa = testing.allocator;
    const backing = try gpa.alloc(u8, layout.bank_size + 1);
    defer gpa.free(backing);
    @memset(backing, 0);

    var set: convert.Set = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .assets = &.{},
        .metatiles = &.{},
        .collision = &.{},
        .solidity = .{ .name = "solidity", .bytes = &.{} },
        .map_cells = &.{},
        .map_screens = &.{},
        .doors = .{ .name = "doors", .bytes = backing },
        .door_pointers = .{ .name = "door_pointers", .bytes = &.{} },
        .load_sources = .{ .name = "load_sources", .bytes = &.{} },
        .physics = &.{},
        .metasprites = &.{},
        .enemies = &.{},
        .aram = &.{},
        .by_basis = .{ 0, 0, 0 },
    };
    defer set.deinit();

    var diag: Diagnosis = .{};
    try testing.expectError(Error.BlobExceedsBank, build(gpa, set, testBoot, &diag));
    try testing.expectEqual(layout.Class.doors, diag.class.?);
    try testing.expect(std.mem.indexOf(u8, diag.message, "doors") != null);
}

/// A boot record for the synthetic sets below. They exist to make injection
/// fail before it reaches the boot record at all, so the values only have to be
/// well formed.
const testBoot: screen.Boot = .{
    .map_index = 0,
    .cell = 0,
    .door_index = 0,
    .tiletable = 0,
    .palette = .{ 0, 0, 0, 0 },
    .obj_palette = @splat(0),
    .samus_x = screen.samusStart(0).x,
    .samus_y = screen.samusStart(0).y,
    .cam_x = screen.samusStart(0).x,
    .cam_y = screen.samusStart(0).y,
};

test "the real set builds a ROM, and everything is where the table says" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();

    const boot = try screen.chooseBoot(gpa, bytes);
    var diag: Diagnosis = .{};
    var rom = build(gpa, set, boot, &diag) catch |e| {
        std.debug.print("build failed: {s}\n", .{diag.message});
        return e;
    };
    defer rom.deinit();

    try testing.expectEqual(layout.romSize(), rom.bytes.len);
    try testing.expectEqual(layout.blobCount(set), rom.placements.len);

    // The engine survived injection byte for byte outside the fields that are
    // deliberately patched: the world table, the boot record with its table
    // list, and the region table. Everything between them, and everything
    // before them, is the image as assembled.
    const bootrec = symbolOffset("BootRecord").?;
    const list = symbolOffset("TileTableBases").?;
    const table = symbolOffset("RegionTable").?;
    const world = symbolOffset("BootWorld").?;
    // `BootWorld` sits *below* the record, so it is the first patched span and
    // the one a "nothing before the record moved" check would have covered by
    // accident. This boot seeds no tiles -- `chooseBoot` invents a spawn, and a
    // spawn has shot nothing -- so the table is untouched here and the seeded
    // case is its own test below.
    try testing.expect(world < bootrec);
    try testing.expectEqualSlices(u8, image[0..world], rom.bytes[0..world]);
    const world_end = world + boot_world_max * boot_world_entry_bytes;
    try testing.expectEqualSlices(u8, image[world..world_end], rom.bytes[world..world_end]);
    try testing.expectEqualSlices(u8, image[world_end..bootrec], rom.bytes[world_end..bootrec]);
    const patched_end = list + tile_table_bytes;
    try testing.expectEqualSlices(u8, image[patched_end..table], rom.bytes[patched_end..table]);
    try testing.expectEqual(bootrec + boot_record_bytes, list);
    // The count is written even when it is zero: the field is $FFFF in an
    // unpatched image, and `SeedWorld` would walk 65 535 entries of it.
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, rom.bytes[bootrec + boot_world_count_at ..][0..2], .little));

    const dir = rom.of(.directory)[0];
    const entries = table + 8;
    for (std.enums.values(layout.Class)) |class| {
        const i: usize = @intFromEnum(class);
        const e = rom.bytes[entries + i * region_entry_bytes ..][0..region_entry_bytes];
        const base = readAddr(e[0..3]);
        try testing.expectEqual(snesAddr(layout.regionStart(class)), base);
        const count = std.mem.readInt(u16, e[6..8], .little);
        const ps = rom.of(class);
        try testing.expectEqual(ps.len, count);
        try testing.expect(count > 0);

        // The class's directory section describes exactly its own blobs, and
        // every address in it resolves to the bytes the blob was built from.
        const sect = try fileOffset(readAddr(e[3..6]));
        try testing.expect(sect >= dir.offset and sect < dir.offset + dir.len);
        for (ps, 0..) |p, k| {
            const ent = rom.bytes[sect + k * directory_entry_bytes ..][0..directory_entry_bytes];
            try testing.expectEqual(p.addr(), readAddr(ent[0..3]));
            try testing.expectEqual(p.id, ent[3]);
            try testing.expectEqual(@as(u16, @intCast(p.len)), std.mem.readInt(u16, ent[4..6], .little));
            const at = try fileOffset(readAddr(ent[0..3]));
            try testing.expectEqual(p.offset, at);
            // Inside its own region, and inside one bank.
            try testing.expect(at >= layout.regionStart(class));
            try testing.expect(at + p.len <= layout.regionStart(class) + layout.reserved[i]);
            try testing.expectEqual(at / layout.bank_size, (at + p.len - 1) / layout.bank_size);
        }
    }

    // Every asset the converted door stream can name is findable by its id in
    // the class the stream's CopyClass selects. That is what the directory
    // exists for, so it is checked rather than assumed.
    for (set.assets) |a| {
        const class: layout.Class = switch (a.kind) {
            .chr_bg => .chr_bg,
            .chr_obj => .chr_obj,
            .tilemap => .tilemap,
        };
        var found = false;
        for (rom.of(class)) |p| {
            if (p.id != a.id) continue;
            found = true;
            try testing.expectEqualSlices(u8, a.bytes, rom.bytes[p.offset..][0..p.len]);
        }
        try testing.expect(found);
    }
}

fn readAddr(src: *const [3]u8) u32 {
    return @as(u32, src[0]) | (@as(u32, src[1]) << 8) | (@as(u32, src[2]) << 16);
}

test "the header describes the cart the builder actually produced" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();
    const boot = try screen.chooseBoot(gpa, bytes);
    var diag: Diagnosis = .{};
    var rom = try build(gpa, set, boot, &diag);
    defer rom.deinit();

    const header = symbolOffset("CartHeader").?;
    // ROM size byte: log2 of the size in KiB, so 512 KiB is 9.
    try testing.expectEqual(
        @as(u8, @intCast(std.math.log2_int(usize, layout.romSize() / 1024))),
        rom.bytes[header + 23],
    );
    // The checksum convention: the two fields are complements, and the sum of
    // every byte in the cart equals the checksum field.
    const checksum = std.mem.readInt(u16, rom.bytes[header + 30 ..][0..2], .little);
    const complement = std.mem.readInt(u16, rom.bytes[header + 28 ..][0..2], .little);
    try testing.expectEqual(checksum, ~complement);
    // The convention sums the cart with the two fields reading $FFFF and $0000,
    // so recreate that state rather than trying to undo it arithmetically.
    const copy = try gpa.dupe(u8, rom.bytes);
    defer gpa.free(copy);
    std.mem.writeInt(u16, copy[header + 28 ..][0..2], 0xFFFF, .little);
    std.mem.writeInt(u16, copy[header + 30 ..][0..2], 0x0000, .little);
    var sum: u16 = 0;
    for (copy) |b| sum +%= b;
    try testing.expectEqual(checksum, sum);
}

test "the same input produces the same bytes" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    // Two full runs from the ROM, not two calls to `build` on one set: the
    // conversion is upstream of the injection, and a hash map iterated in
    // address order there would be just as much of a determinism bug.
    var first_digest: [32]u8 = undefined;
    var second_digest: [32]u8 = undefined;
    for ([_]*[32]u8{ &first_digest, &second_digest }) |slot| {
        var set = try convert.run(gpa, bytes);
        defer set.deinit();
        const boot = try screen.chooseBoot(gpa, bytes);
        var diag: Diagnosis = .{};
        var rom = try build(gpa, set, boot, &diag);
        defer rom.deinit();
        slot.* = rom.digest();
    }
    try testing.expectEqualSlices(u8, &first_digest, &second_digest);
}

// ---- Reading the finished cart the way the engine does ---------------------

const map = @import("map.zig");

/// One region-table entry, read back out of an injected image.
const Region = struct { base: u32, dir: u32, count: u16 };

fn regionOf(rom: Rom, class: layout.Class) Region {
    const at = symbolOffset("RegionTable").? + 8 + @intFromEnum(class) * region_entry_bytes;
    const e = rom.bytes[at..][0..region_entry_bytes];
    return .{
        .base = readAddr(e[0..3]),
        .dir = readAddr(e[3..6]),
        .count = std.mem.readInt(u16, e[6..8], .little),
    };
}

/// Where a blob landed in the cart, as a 24-bit address.
///
/// The same two indirections `findBlob` walks, returning the address rather
/// than the bytes -- which is what the engine's own `.collFound` stores into
/// `!ColTab` (engine/main.asm, `lda !Blob / sta !ColTab`). A caller that wants
/// to point the engine at a different table writes exactly this number.
pub fn blobAddress(rom: Rom, class: layout.Class, id: u8) ?u32 {
    const r = regionOf(rom, class);
    const dir = fileOffset(r.dir) catch return null;
    for (0..r.count) |i| {
        const e = rom.bytes[dir + i * directory_entry_bytes ..][0..directory_entry_bytes];
        if (e[3] != id) continue;
        return readAddr(e[0..3]);
    }
    return null;
}

/// A blob's bytes, by class and id. `findBlob`'s walk, made available to the
/// test-script generator so it can ask what the cart actually carries.
pub fn blobBytes(rom: Rom, class: layout.Class, id: u8) ?[]const u8 {
    return findBlob(rom, class, id);
}

/// The two indirections `FindBlob` performs in 65816: class to directory, then
/// id to address. Written out here so the tests below walk the cart the way the
/// cart walks itself - a directory that only the injector can read would prove
/// nothing about the engine.
fn findBlob(rom: Rom, class: layout.Class, id: u8) ?[]const u8 {
    const r = regionOf(rom, class);
    const dir = fileOffset(r.dir) catch return null;
    for (0..r.count) |i| {
        const e = rom.bytes[dir + i * directory_entry_bytes ..][0..directory_entry_bytes];
        if (e[3] != id) continue;
        const at = fileOffset(readAddr(e[0..3])) catch return null;
        return rom.bytes[at..][0..std.mem.readInt(u16, e[4..6], .little)];
    }
    return null;
}

test "the boot record names the screen the builder chose" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();
    const boot = try screen.chooseBoot(gpa, bytes);
    var diag: Diagnosis = .{};
    var rom = try build(gpa, set, boot, &diag);
    defer rom.deinit();

    const at = symbolOffset("BootRecord").?;
    try testing.expectEqualSlices(u8, boot_magic, rom.bytes[at..][0..4]);
    try testing.expectEqual(boot_version, rom.bytes[at + 4]);
    try testing.expectEqual(boot.map_index, rom.bytes[at + 5]);
    try testing.expectEqual(boot.cell, rom.bytes[at + 6]);
    try testing.expectEqual(@as(u8, boot.tiletable), rom.bytes[at + 7]);
    try testing.expectEqual(boot.door_index, std.mem.readInt(u16, rom.bytes[at + 8 ..][0..2], .little));
    for (screen.palette(screens.live_bgp), 0..) |colour, i| {
        try testing.expectEqual(colour, std.mem.readInt(u16, rom.bytes[at + 10 + i * 2 ..][0..2], .little));
    }
    // Version 3: her start position and pose, which the engine used to build
    // for itself out of the cell nibbles.
    try testing.expectEqual(boot.samus_y, std.mem.readInt(u16, rom.bytes[at + boot_samus_y_at ..][0..2], .little));
    try testing.expectEqual(boot.samus_x, std.mem.readInt(u16, rom.bytes[at + boot_samus_x_at ..][0..2], .little));
    try testing.expectEqual(boot.pose, rom.bytes[at + boot_pose_at]);

    // And the default is the number version 2's engine computed: the boot
    // cell's nibbles over the middle of a screen. Written out here rather than
    // called through `samusStart`, so the test would fail if that function
    // changed rather than agreeing with it.
    try testing.expectEqual(
        (@as(u16, boot.cell & 0x0F) << 8) | screen.start_x,
        boot.samus_x,
    );
    try testing.expectEqual(
        (@as(u16, boot.cell >> 4) << 8) | screen.start_y,
        boot.samus_y,
    );
    try testing.expectEqual(screen.pose.fall, boot.pose);

    // A chosen screen is a real one: in a real map bank, at a real cell, and
    // named by a door that exists.
    try testing.expect(boot.map_index < map.bank_count);
    try testing.expect(boot.door_index * 2 < set.door_pointers.bytes.len);
}

test "the boot record carries the new game's loadout, off the ROM" {
    // Version 11. Every cart before it booted with zero health and zero
    // missiles, which is how a playtest fired a missile and got the dud. The
    // numbers are the ROM's `initialSaveFile` (01:$4E64) through
    // `save.initial`; they are written out here so a decode that drifted would
    // fail rather than agree with itself.
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    const want: screen.Loadout = .{
        .tanks = 0x00,
        .health = 0x0099,
        .max_missiles = 0x0030,
        .missiles = 0x0030,
        .metroid_real = 0x47,
        .metroid_displayed = 0x39,
        .items = 0x00,
        .beam = 0x00,
        .active_weapon = 0x00,
        .song = 0x00,
        // The room's song, `initialSaveFile`'s "Song for room": the main caves.
        // Zero here until Step 18, which is the whole of why a new game played
        // nothing (`docs/bug_tracker.md`, 2026-09-22).
        .room_song = 0x04,
        // `initialSaveFile`'s damage values. Zero until Step 22, and acid
        // took nothing off.
        .acid_damage = 0x02,
        .spike_damage = 0x08,
    };
    try testing.expectEqual(want, screen.Loadout.newGame(bytes).?);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();
    const boot = try screen.chooseBoot(gpa, bytes);
    try testing.expectEqual(want, boot.loadout);
    var diag: Diagnosis = .{};
    var rom = try build(gpa, set, boot, &diag);
    defer rom.deinit();

    const at = symbolOffset("BootRecord").?;
    try testing.expectEqual(want.tanks, rom.bytes[at + boot_tanks_at]);
    try testing.expectEqual(want.health, std.mem.readInt(u16, rom.bytes[at + boot_health_at ..][0..2], .little));
    try testing.expectEqual(want.max_missiles, std.mem.readInt(u16, rom.bytes[at + boot_max_missiles_at ..][0..2], .little));
    try testing.expectEqual(want.missiles, std.mem.readInt(u16, rom.bytes[at + boot_missiles_at ..][0..2], .little));
    try testing.expectEqual(want.metroid_real, rom.bytes[at + boot_metroid_real_at]);
    try testing.expectEqual(want.metroid_displayed, rom.bytes[at + boot_metroid_displayed_at]);
    // And the offsets are the engine's, not a second opinion about them.
    try testing.expectEqual(symbolOffset("BootTanks").? - at, boot_tanks_at);
    try testing.expectEqual(symbolOffset("BootHealth").? - at, boot_health_at);
    try testing.expectEqual(symbolOffset("BootMaxMiss").? - at, boot_max_missiles_at);
    try testing.expectEqual(symbolOffset("BootCurMiss").? - at, boot_missiles_at);
    try testing.expectEqual(symbolOffset("BootMetReal").? - at, boot_metroid_real_at);
    try testing.expectEqual(symbolOffset("BootMetDisp").? - at, boot_metroid_displayed_at);
    try testing.expectEqual(symbolOffset("BootCannonChr").? - at, boot_cannon_chr_at);
    try testing.expectEqual(want.items, rom.bytes[at + boot_items_at]);
    try testing.expectEqual(want.beam, rom.bytes[at + boot_beam_at]);
    try testing.expectEqual(want.active_weapon, rom.bytes[at + boot_weapon_at]);
    try testing.expectEqual(symbolOffset("BootItems").? - at, boot_items_at);
    try testing.expectEqual(symbolOffset("BootBeam").? - at, boot_beam_at);
    try testing.expectEqual(symbolOffset("BootWeapon").? - at, boot_weapon_at);
    try testing.expectEqual(want.song, rom.bytes[at + boot_song_at]);
    try testing.expectEqual(symbolOffset("BootSong").? - at, boot_song_at);
    try testing.expectEqual(want.room_song, rom.bytes[at + boot_room_song_at]);
    try testing.expectEqual(symbolOffset("BootRoomSong").? - at, boot_room_song_at);
    try testing.expectEqual(want.acid_damage, rom.bytes[at + boot_acid_at]);
    try testing.expectEqual(symbolOffset("BootAcid").? - at, boot_acid_at);
    try testing.expectEqual(want.spike_damage, rom.bytes[at + boot_spike_at]);
    try testing.expectEqual(symbolOffset("BootSpike").? - at, boot_spike_at);
}

test "the fields InitState loads directly are read by the engine, though BootSeed does not carry them" {
    // `BootSeed` is for record bytes that become direct-page *variables*. The
    // version 3 and version 4 fields are not: `InitState` reads them straight
    // out of the record with an absolute load. So the seeding table cannot vouch
    // for them, and without something that can, a field could be written into
    // every cart and never looked at -- which for a start position would look
    // exactly like it working, because the default is where she would have gone
    // anyway. `BootCamX`/`BootCamY` are the sharper case: their default *is*
    // her position, so an unread camera field is invisible on every cart the
    // Phase 0a pipeline builds and only shows up against a movie.
    //
    // What this checks is that the engine image contains an absolute load of
    // each field's address. Not that it uses the value sensibly; that is the
    // gate's job. Just that the wire is connected at both ends.
    for ([_][]const u8{ "BootSamusX", "BootSamusY", "BootPose", "BootCamX", "BootCamY", "BootTanks", "BootHealth", "BootMaxMiss", "BootCurMiss", "BootMetReal", "BootMetDisp", "BootItems", "BootBeam", "BootWeapon", "BootSong", "BootRoomSong", "BootAcid", "BootSpike" }) |name| {
        const off = symbolOffset(name) orelse return error.NoBootField;
        const addr = snesAddr(off);
        const lo: u8 = @truncate(addr);
        const hi: u8 = @truncate(addr >> 8);

        var found = false;
        var i: usize = 0;
        while (i + 2 < image.len) : (i += 1) {
            // $AD is LDA absolute, which is what `lda.w Label` assembles to.
            if (image[i] == 0xAD and image[i + 1] == lo and image[i + 2] == hi) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("no absolute load of {s} (${X:0>6}) in the engine image\n", .{ name, addr });
            return error.BootFieldNeverRead;
        }
    }
}

test "every metatile table base points at the table it names" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();
    const boot = try screen.chooseBoot(gpa, bytes);
    var diag: Diagnosis = .{};
    var rom = try build(gpa, set, boot, &diag);
    defer rom.deinit();

    var tabs = try render.tables(gpa, set);
    defer tabs.deinit(gpa);

    const list = symbolOffset("TileTableBases").?;
    for (tabs.base, 0..) |base, slot| {
        const addr = readAddr(rom.bytes[list + slot * 3 ..][0..3]);
        const off = try fileOffset(addr);
        // From this base to the end of the run is what a screen may index, so
        // that whole tail has to match - not just the table's own bytes. This
        // is the property bank-packing the tables would have broken.
        const tail = tabs.bytes[base..];
        try testing.expectEqualSlices(u8, tail, rom.bytes[off..][0..tail.len]);
    }
}

test "the cart holds the boot screen the reference renderer would draw" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();
    const boot = try screen.chooseBoot(gpa, bytes);
    var diag: Diagnosis = .{};
    var rom = try build(gpa, set, boot, &diag);
    defer rom.deinit();

    // Everything below is read out of the finished image through the region
    // table and the directory, which is the path the engine takes. Nothing
    // consults `set` until the comparison at the end.
    const cells = findBlob(rom, .map_cells, boot.map_index) orelse return error.MissingMapCells;
    const cell = cells[@as(usize, boot.cell) * convert.cell_bytes ..][0..convert.cell_bytes];
    const screen_index = cell[0];
    try testing.expect(screen_index != convert.null_screen);

    const bodies = findBlob(rom, .map_screens, boot.map_index) orelse return error.MissingMapScreens;
    const body = bodies[@as(usize, screen_index) * map.screen_bytes ..][0..map.screen_bytes];

    const list = symbolOffset("TileTableBases").?;
    const meta_at = try fileOffset(readAddr(rom.bytes[list + @as(usize, boot.tiletable) * 3 ..][0..3]));
    const run = rom.of(.metatiles);
    const run_end = run[run.len - 1].offset + run[run.len - 1].len;
    const metatiles = rom.bytes[meta_at..run_end];

    var from_cart: screen.Tilemap = undefined;
    const cart_stats = screen.buildTilemap(&from_cart, body, metatiles, .none);

    // And the same screen from the converted set, which is what
    // `snes_render.zig` draws the 904-screen comparison from.
    var tabs = try render.tables(gpa, set);
    defer tabs.deinit(gpa);
    var expected: screen.Tilemap = undefined;
    const set_stats = screen.buildTilemap(
        &expected,
        set.map_screens[boot.map_index].bytes[@as(usize, screen_index) * map.screen_bytes ..][0..map.screen_bytes],
        tabs.table(boot.tiletable),
        .none,
    );

    try testing.expectEqualSlices(u16, &expected, &from_cart);
    try testing.expectEqual(set_stats.out_of_range, cart_stats.out_of_range);
    try testing.expectEqual(@as(usize, 0), cart_stats.out_of_range);
    // A tilemap of nothing but character zero would pass every check above and
    // still be a black screen, so require the screen to have content.
    var distinct: usize = 0;
    for (from_cart) |w| {
        if (w != from_cart[0]) distinct += 1;
    }
    try testing.expect(distinct > 64);
}

test "the boot script fills the VRAM the boot screen reads" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();
    const boot = try screen.chooseBoot(gpa, bytes);

    // The engine replays exactly one script at boot. Most screens are fine with
    // that and 72 of the 904 are not - they draw with characters an *earlier*
    // room left in VRAM, which a cart that boots straight into them would show
    // as garbage. The boot screen has to be one of the ones that stands alone,
    // and this is the check that says so.
    const start = std.mem.readInt(u16, set.door_pointers.bytes[@as(usize, boot.door_index) * 2 ..][0..2], .little);
    const vram = try render.vramFor(set, set.doors.bytes[start..]);

    var tabs = try render.tables(gpa, set);
    defer tabs.deinit(gpa);
    const cells = set.map_cells[boot.map_index].bytes;
    const screen_index = cells[@as(usize, boot.cell) * convert.cell_bytes];
    const body = set.map_screens[boot.map_index].bytes[@as(usize, screen_index) * map.screen_bytes ..][0..map.screen_bytes];

    var drawn = try render.renderScreen(
        gpa,
        body,
        tabs.table(boot.tiletable),
        vram,
        render.paletteFromBgp(screens.live_bgp),
        .none,
    );
    defer drawn.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), drawn.unwritten_chars);
    try testing.expectEqual(@as(usize, 0), drawn.out_of_range);
}

test "the engine's camera limits are the model's" {
    // No ROM needed: this reads the committed image directly. The engine's step
    // routines use the same assembler defines the table is built from, so what
    // this pins is the pair of files, not one number in one of them.
    const at = symbolOffset("CameraLimits") orelse return error.NoCameraLimits;
    const want = [_]u16{
        screen.min_x,   screen.max_x,   screen.min_y, screen.max_y,
        screen.start_x, screen.start_y, screen.cam_step,
    };
    for (want, 0..) |v, i| {
        try testing.expectEqual(v, std.mem.readInt(u16, image[at + i * 2 ..][0..2], .little));
    }
}

test "every mutable field of the boot record is actually seeded" {
    // The record carries three bytes the engine keeps in variables and then
    // changes as it runs: the map, the cell, and the metatile table. Nothing
    // stops a value being written into the image and never read back out - the
    // engine would run on whatever the WRAM clear left, which is a zero that
    // looks like a perfectly reasonable map index. So the seeding is a table,
    // and this reads it.
    const seed = symbolOffset("BootSeed") orelse return error.NoBootSeed;
    const boot = symbolOffset("BootRecord") orelse return error.NoBootRecord;

    var seen: [boot_record_bytes]bool = @splat(false);
    var at = seed;
    while (image[at] != 0xFF) : (at += 2) {
        const field = image[at];
        try testing.expect(field < boot_record_bytes);
        try testing.expect(!seen[field]); // seeded once, not twice
        seen[field] = true;
        // The destination is a direct-page variable, and direct page is zero.
        try testing.expect(image[at + 1] < 0x80);
    }

    // Exactly the three mutable bytes: map index, cell, tile table. The magic,
    // the version, the door index and the palette are read where they are used
    // and never change, so they are deliberately absent.
    try testing.expect(seen[5] and seen[6] and seen[7]);
    for (seen, 0..) |s, i| {
        if (i == 5 or i == 6 or i == 7) continue;
        try testing.expect(!s);
    }
    _ = boot;
}

test "the engine's title-art constants are title_super's" {
    // Step 24j. The engine reads "Super"'s blobs by class and id, skips the
    // map patch's header by its length, and uploads the palette to the
    // converter's BG palette; each is a hand-written mirror.
    const ts = @import("title_super.zig");
    try testing.expectEqual(@as(u32, @intFromEnum(layout.Class.title_art)), symbol("ConstClassTitleArt").?);
    try testing.expectEqual(@as(u32, ts.map_header_bytes), symbol("ConstTitleArtHeader").?);
    try testing.expectEqual(@as(u32, @as(u32, ts.palette) * 16), symbol("ConstTitleArtCgram").?);
    try testing.expectEqual(@as(u32, 2), symbol("ConstTitleArtMap").?);
    try testing.expectEqual(@as(u32, target.bg12_char_base), @as(u32, 0x1000));
}

test "the debug menu's digits are the readout's, in colour 1" {
    // 1.0 Step 4. The same seventeen glyphs, drawn white beside the item
    // font's letters: plane 0 is the readout's rows and plane 1 is empty.
    const r = symbolOffset("ReadoutFont").?;
    const d = symbolOffset("DebugHexFont").?;
    const n = symbolOffset("DebugHexFontEnd").? - d;
    try testing.expectEqual(symbolOffset("ReadoutFontEnd").? - r, n);
    var i: usize = 0;
    while (i < n) : (i += 2) {
        try testing.expectEqual(image[r + i], image[d + i]);
        try testing.expectEqual(@as(u8, 0), image[d + i + 1]);
    }
}

test "the engine's debug-table constants are debug_tables'" {
    // 1.0 Step 4. The menu finds its two lists by class and id and walks their
    // entries by size; each is a hand-written mirror.
    const dt = @import("debug_tables.zig");
    try testing.expectEqual(@as(u32, @intFromEnum(layout.Class.debug)), symbol("ConstClassDebug").?);
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.metroids)), symbol("ConstDebugBlobMetroids").?);
    try testing.expectEqual(@as(u32, dt.queen_bank), symbol("ConstDebugQueenBank").?);
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.larvae)), symbol("ConstDebugBlobLarvae").?);
    try testing.expectEqual(@as(u32, dt.larvae_rows_at), symbol("ConstDebugLarvaeRows").?);
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.flags)), symbol("ConstDebugBlobFlags").?);
    try testing.expectEqual(@as(u32, dt.entry_bytes), symbol("ConstDebugEntry").?);
    try testing.expectEqual(@as(u32, dt.header_bytes), symbol("ConstDebugLabel").?);
    // Step 5b's: the WARP page's lists, and the entry its rows run.
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.warp_saves)), symbol("ConstDebugBlobWarpSaves").?);
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.warp_items)), symbol("ConstDebugBlobWarpItems").?);
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.warp_metroids)), symbol("ConstDebugBlobWarpMetroids").?);
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.warp_queen)), symbol("ConstDebugBlobWarpQueen").?);
    try testing.expectEqual(@as(u32, @intFromEnum(dt.Which.warp_data)), symbol("ConstDebugBlobWarpData").?);
    try testing.expectEqual(@as(u32, dt.warp_bytes), symbol("ConstWarpBytes").?);
}

test "the gate's RAM addresses are the engine's, not a copy of them" {
    // `snes_screen.ram` is a hand-written mirror of `engine/main.asm`'s direct
    // page, and until now nothing checked it. A wrong address there does not
    // fail: the Lua gate reads a neighbouring variable, the value looks
    // plausible, and the assertion passes on the wrong byte. That is the same
    // failure `correspond.zig` exists to prevent on the Game Boy side, and it
    // cost Step 15 three sessions there.
    //
    // The `Var*` symbols assemble to nothing and cost nothing, so every
    // mirrored address that has one is checked against it here. The ones with
    // no symbol are listed as such rather than skipped silently.
    const scr = @import("snes_screen.zig");
    const pairs = .{
        .{ "VarFrameCount", scr.ram.frame_count },
        .{ "VarMapIndex", scr.ram.map_index },
        .{ "VarCell", scr.ram.cell },
        .{ "VarCamX", scr.ram.cam_x },
        .{ "VarCamY", scr.ram.cam_y },
        .{ "VarInputPressed", scr.ram.input_pressed },
        .{ "VarInputRisingEdge", scr.ram.input_rising_edge },
        .{ "VarSamusX", scr.ram.samus_x },
        .{ "VarSamusY", scr.ram.samus_y },
        .{ "VarPose", scr.ram.pose },
        .{ "VarFacing", scr.ram.facing },
        .{ "VarJumpArc", scr.ram.jump_arc },
        .{ "VarUnhandled", scr.ram.unhandled },
        .{ "VarDoorIndex", scr.ram.door_index },
        .{ "VarTransDir", scr.ram.trans_dir },
        .{ "VarTilemapBuf", scr.ram.tilemap_buf },
        .{ "VarCountdown", scr.ram.countdown },
        .{ "VarOamIdx", scr.ram.oam_index },
        .{ "VarItems", scr.ram.items },
        .{ "VarItemCollected", scr.ram.item_collected },
        .{ "VarItemStage", scr.ram.item_stage },
        .{ "VarItemFlag", scr.ram.item_flag },
    };
    inline for (pairs) |p| {
        const addr = symbol(p[0]) orelse {
            std.debug.print("no symbol {s}\n", .{p[0]});
            return error.MissingSymbol;
        };
        testing.expectEqual(@as(u32, p[1]), addr) catch |e| {
            std.debug.print("{s}: gate says ${X:0>4}, engine says ${X:0>4}\n", .{ p[0], p[1], addr });
            return e;
        };
    }
    // `sprite_id`, `sprite_x`, `sprite_y` and `oam_index` have no `Var*` export
    // -- they are drawing state the oracle does not compare -- so they stay
    // mirrored by hand. Named here so the gap is a sentence rather than a
    // silence.
}

test "the title screen's four sheets are one gapless $1000 run" {
    // The claim `bank_005.asm` states in a comment, checked against the
    // addresses: `title_loadGraphics` moves $1000 bytes in one copy and the
    // four entries have to account for all of it, in this order. It is what
    // makes the character rotation in `snes_target.charForTitleId` meaningful
    // -- a run with a gap in it would put every tile after the gap at the wrong
    // character and the tilemap would index past them.
    const len = titleRunLen() orelse return error.TitleRunNotContiguous;
    try testing.expectEqual(@as(usize, 0x1000), len);

    // And it ends where the next thing in the bank begins, which is the far end
    // no listing gave us.
    const first = offsets_table.find(title_sheets[0]).?;
    const next = offsets_table.find("gfx_creditsSprTiles").?;
    try testing.expectEqual(next.romOffset(), first.romOffset() + len);
}

test "a record that shot blocks out carries them, and one too damaged is refused" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);
    var set = try convert.run(gpa, bytes);
    defer set.deinit();

    var boot = try screen.chooseBoot(gpa, bytes);
    // Four tiles of $FF, which is what `destroyBlock` (01:56E9) writes over the
    // 2x2 it clears -- so this is one block, in the shape the game makes them.
    const holes = [_]screen.WorldSeed{
        .{ .index = 300, .tile = 0xFF },
        .{ .index = 301, .tile = 0xFF },
        .{ .index = 332, .tile = 0xFF },
        .{ .index = 333, .tile = 0xFF },
    };
    boot.world = &holes;

    var diag: Diagnosis = .{};
    var rom = build(gpa, set, boot, &diag) catch |e| {
        std.debug.print("build failed: {s}\n", .{diag.message});
        return e;
    };
    defer rom.deinit();

    const at = symbolOffset("BootRecord").?;
    const world = symbolOffset("BootWorld").?;
    try testing.expectEqual(
        @as(u16, holes.len),
        std.mem.readInt(u16, rom.bytes[at + boot_world_count_at ..][0..2], .little),
    );
    for (holes, 0..) |h, i| {
        const e = world + i * boot_world_entry_bytes;
        try testing.expectEqual(h.index, std.mem.readInt(u16, rom.bytes[e..][0..2], .little));
        try testing.expectEqual(h.tile, rom.bytes[e + 2]);
    }
    // Everything past what was written is the fill the image assembled with, so
    // a short list cannot leave a previous build's holes behind it.
    try testing.expectEqual(@as(u8, 0xFF), rom.bytes[world + holes.len * boot_world_entry_bytes]);

    // More holes than the table holds is refused rather than truncated: a cart
    // seeded with some of the floor missing has a floor the reference does not,
    // and would grade as a port bug rather than as a build that stopped.
    const too_many = try gpa.alloc(screen.WorldSeed, boot_world_max + 1);
    defer gpa.free(too_many);
    for (too_many, 0..) |*w, i| w.* = .{ .index = @intCast(i), .tile = 0xFF };
    boot.world = too_many;
    var diag2: Diagnosis = .{};
    try testing.expectError(Error.PatchTableMismatch, build(gpa, set, boot, &diag2));
}
