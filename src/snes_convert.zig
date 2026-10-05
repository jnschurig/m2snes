//! Converting the extracted Game Boy assets into the forms the SNES engine
//! reads at runtime.
//!
//! The through-line is that a conversion should be *reversible* wherever the
//! formats permit, because a reversible conversion can be checked against the
//! ROM and an irreversible one can only be inspected. So every table here has
//! an inverse beside it and the gate closes the loop, exactly as Step 5 did for
//! extraction. Where a conversion genuinely loses something - a Game Boy bank
//! number becoming a map index, a source address becoming an asset id - the
//! inverse takes the lost part as an argument rather than pretending to
//! recover it.
//!
//! What each class becomes:
//!
//!   graphics    2bpp characters for BG3, 4bpp for objects, sometimes both.
//!               See `target.zig` on why the same sheet can need two depths.
//!   metatiles   four SNES tilemap words per 16x16 metatile, TL TR BL BR,
//!               with palette and priority baked from `target.zig`.
//!   collision   unchanged: one behaviour byte per tile id.
//!   physics     the jump, fall and space-jump arcs as raw signed speeds, with
//!               the `$80` terminator dropped: the blob's length carries what
//!               the terminator carried, so the engine caps its counter with a
//!               compare instead of scanning for a sentinel.
//!   solidity    unchanged: eight rows of three thresholds.
//!   map         per bank, 256 cells of {screen, scroll, transition} plus the
//!               59 screen bodies, which stay 256 raw metatile indexes each.
//!   doors       the same opcode stream with relocated operands - see
//!               `convertScript`.

const std = @import("std");
const offsets = @import("offsets.zig");
const gfx = @import("gfx.zig");
const tileset = @import("tileset.zig");
const map = @import("map.zig");
const door = @import("door.zig");
const target = @import("snes_target.zig");
const chr = @import("snes_chr.zig");
const screens = @import("screens.zig");
const physics = @import("physics.zig");
const sprites = @import("sprites.zig");
const entity = @import("entity.zig");
const save = @import("save.zig");
const aram_image = @import("aram_image.zig");
const title_super = @import("title_super.zig");
const debug_tables = @import("debug_tables.zig");
const gfx_info = @import("gfx_info.zig");
const warp = @import("warp.zig");

pub const Error = error{
    /// A door script names a source address that falls in no offsets entry.
    /// The extractor already gates on this being zero; repeating the check
    /// here means the converter cannot quietly emit a dangling asset id.
    UnresolvedSource,
    /// A `WARP` names a bank outside $9-$F. Map banks are the only thing a
    /// warp can select, so this would be a misparse rather than a surprise.
    WarpBankOutOfRange,
    /// More assets than an 8-bit id can name.
    TooManyAssets,
    /// A `COPY_BG` into `$8800`-`$8FFF`. The retail ROM has none. Split like
    /// the others, its object half would come first and the engine would
    /// store its source as the enemy graphics', where the Game Boy stores it
    /// as the background's; refused rather than converted wrongly.
    SharedWindowBgCopy,
    /// A metatile table whose length is not a whole number of metatiles.
    RaggedMetatileTable,
    /// An arc that does not come back out of `physics.encodeArc` as the bytes
    /// it was read from, which would mean the entry's size is wrong.
    ArcDoesNotReencode,
    /// A spawn list region that does not come back out of
    /// `entity.encodeSpawnLists` as the bytes it was parsed from.
    SpawnListDoesNotReencode,
    /// A screen's spawn pointer that names no list start. Nothing in this ROM
    /// does; the refusal is what says so.
    SpawnPointerOffAList,
    /// An enemy header region that does not come back out of
    /// `entity.encodeHeaders` as the bytes it was parsed from.
    HeaderDoesNotReencode,
    /// An enemy id whose header pointer leaves the header region, or lands
    /// between two of its 11-byte records. Neither happens in this ROM.
    HeaderPointerOutOfRange,
    HeaderPointerOffARecord,
    /// An enemy hitbox region that does not come back out of
    /// `entity.encodeHitboxes` as the bytes it was parsed from.
    HitboxDoesNotReencode,
    /// More than one hitbox pointer that names no record. The retail ROM has
    /// exactly one -- id $9A's $C360 -- and the count is asserted rather than
    /// tolerated, because a second one would mean the region's bounds moved.
    HitboxPointerOutOfRange,
    /// A damage table that is not one byte per enemy id.
    DamageTableWrongLength,
    /// A metasprite record that does not come back out of `entity.encodeMetasprites`
    /// as the bytes it went in as.
    MetaspriteDoesNotReencode,
} || target.DestError || door.Error || map.Error || tileset.Error || physics.Error ||
    physics.HitboxError || sprites.Error || entity.Error;

// ---- Assets ---------------------------------------------------------------

/// What a converted blob is for. The depth is not a property of the source -
/// the same sheet can be needed at both - so it lives here rather than on the
/// offsets entry.
pub const AssetKind = enum {
    /// 2bpp characters for BG3.
    chr_bg,
    /// 4bpp characters for objects.
    chr_obj,
    /// Tilemap words.
    tilemap,

    pub fn className(self: AssetKind) []const u8 {
        return switch (self) {
            .chr_bg => "chr_bg",
            .chr_obj => "chr_obj",
            .tilemap => "tilemap",
        };
    }
};

/// How we decided an asset needs converting at a given depth. Recorded per
/// asset because the two answers are not equally strong: `door_op` means a door
/// script was seen loading it that way, and `entry_kind` means nothing in the
/// scripts mentions it and the offsets table's classification is standing in.
pub const Basis = enum { door_op, shared_window, entry_kind };

pub const Asset = struct {
    id: u8,
    name: []const u8,
    kind: AssetKind,
    basis: Basis,
    /// Where the Game Boy bytes start in the ROM. The offsets entry's base for
    /// every asset but a load window (`loadWindow`), which has no entry.
    rom_at: usize,
    gb_bytes: usize,
    bytes: []u8,
};

/// Which door-script variants were seen targeting each offsets entry.
const Usage = struct {
    bg: bool = false,
    spr: bool = false,
    data: bool = false,
    /// A `data` copy landed in `$8800`-`$8FFF`, where the Game Boy's objects
    /// read the same bytes its background does: `gfx_commonItems` to $8F00.
    shared: bool = false,
    /// The title's copy lands part of this entry in that same window, so the
    /// title's objects read it: `gfx_titleScreen`'s first $800 bytes. Not a
    /// door operation, so `any` leaves it out. Step 24h.
    title_obj: bool = false,
    /// A copy `prepareCredits` makes starts at this entry and lands in the
    /// objects' $8000-$8FFF: `gfx_creditsSprTiles` and `gfx_creditsNumbers`.
    /// Not a door operation either. 1.0 Step 22.
    credits_obj: bool = false,
    /// The furthest byte past the entry's base that any door operation reads.
    ///
    /// This is not always inside the entry. `LOAD` takes its length from the
    /// handler at 0:`$26EB` - `$0800` for bg, `$0400` for spr - and not from
    /// the size of whatever it is pointed at, so the three `$530`-byte
    /// `lavaCaves` sheets are read `$2D0` bytes past their own end, into
    /// whatever follows them in the bank. `screens.zig` reproduces that
    /// deliberately, because the reference frames are meant to be what the
    /// Game Boy draws rather than what a tidier engine would. An asset cut off
    /// at its entry boundary could not reproduce it, so the converted asset is
    /// as long as the reads demand.
    read_end: usize = 0,

    fn any(self: Usage) bool {
        return self.bg or self.spr or self.data;
    }
};

/// Walk every door script and record how each source entry is loaded.
fn surveyUsage(allocator: std.mem.Allocator, ops: []const door.Op) !std.StringArrayHashMapUnmanaged(Usage) {
    var seen: std.StringArrayHashMapUnmanaged(Usage) = .empty;
    errdefer seen.deinit(allocator);
    for (ops) |op| {
        const src: struct { bank: u8, addr: u16, len: u16, which: enum { bg, spr, data } } = switch (op) {
            .load => |l| .{ .bank = l.src_bank, .addr = l.src_addr, .which = switch (l.which) {
                .bg => .bg,
                .spr => .spr,
            }, .len = switch (l.which) {
                .bg => screens.load_bg_len,
                .spr => screens.load_spr_len,
            } },
            .copy => |c| .{ .bank = c.src_bank, .addr = c.src_addr, .len = c.len, .which = switch (c.which) {
                .bg => .bg,
                .spr => .spr,
                .data => .data,
            } },
            else => continue,
        };
        const resolved = door.resolveSource(src.bank, src.addr) orelse return Error.UnresolvedSource;
        const gop = try seen.getOrPut(allocator, resolved.name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        switch (src.which) {
            .bg => gop.value_ptr.bg = true,
            .spr => gop.value_ptr.spr = true,
            .data => gop.value_ptr.data = true,
        }
        if (op == .copy and op.copy.which != .spr and target.inSharedWindow(op.copy.dest)) gop.value_ptr.shared = true;
        const end = resolved.delta + src.len;
        if (end > gop.value_ptr.read_end) gop.value_ptr.read_end = end;
    }
    return seen;
}

/// Whether an entry needs a given depth, and on what evidence.
///
/// The rules, in the order they apply:
///
///  1. A `tilemap` entry is tilemap words. Nothing else is.
///  2. A door script loading it as `bg` or `data` means BG characters, and
///     loading it as `spr` means object characters. Observed, so `door_op`.
///  3. A sheet loaded as `spr` *also* needs BG characters, because `LOAD_spr`'s
///     $8B00 destination is inside the background's signed window and the
///     surface and queen metatile tables genuinely reach into it. Derived from
///     the hardware rather than observed per sheet, so `shared_window`. The
///     converse holds too: a `data` copy into that window also needs object
///     characters, because the objects read it -- `gfx_commonItems` at $8F00
///     is the missile door, the drops and the item orb.
///     The title's copy is the same case with no door script in it:
///     `title_loadGraphics` puts its run at $8800, so the entries whose bytes
///     land below $9000 are object characters as well (`markTitleWindow`).
///  4. Anything no door script mentions is classified by the offsets table's
///     own kind. This is the weakest rule and the only one that can be wrong
///     without the data contradicting it, which is why `Report` counts how many
///     assets rest on it.
fn basisFor(kind: offsets.Kind, usage: Usage, want: AssetKind) ?Basis {
    if (kind == .tilemap) return if (want == .tilemap) .entry_kind else null;
    if (want == .tilemap) return null;
    if (want == .chr_obj and (usage.title_obj or usage.credits_obj)) return .shared_window;

    if (usage.any()) {
        return switch (want) {
            .chr_bg => if (usage.bg or usage.data) .door_op else if (usage.spr) .shared_window else null,
            .chr_obj => if (usage.spr) .door_op else if (usage.shared) .shared_window else null,
            .tilemap => unreachable,
        };
    }

    const by_kind: ?AssetKind = switch (kind) {
        .graphics_tileset, .graphics_ui, .graphics_item => .chr_bg,
        .graphics_samus, .graphics_enemy => .chr_obj,
        else => null,
    };
    if (by_kind) |k| if (k == want) return .entry_kind;
    return null;
}

/// `title_loadGraphics` (05:$42C7): `LD BC,len / LD HL,src / LD DE,dest` and a
/// copy. Read off the ROM rather than restated, so the rule below is the
/// routine's and not a list of names.
pub const TitleCopy = struct { src: u16, dest: u16, len: u16 };
pub const title_copy_at: u16 = 0x42C7;

pub fn titleCopy(rom: []const u8) ?TitleCopy {
    const at = 5 * offsets.bank_size + (title_copy_at - 0x4000);
    const b = rom[at..][0..9];
    if (b[0] != 0x01 or b[3] != 0x21 or b[6] != 0x11) return null;
    return .{
        .len = std.mem.readInt(u16, b[1..3], .little),
        .src = std.mem.readInt(u16, b[4..6], .little),
        .dest = std.mem.readInt(u16, b[7..9], .little),
    };
}

/// The credits' four copies, `credits_loadFont` (05:$4030) and the three in
/// `prepareCredits` (05:$58D4, $58E0, $58EC), each `LD BC / LD HL / LD DE` and
/// a call to `copyToVram`, read off the ROM as `titleCopy` reads its one.
pub const credits_copies_at = [_]u16{ 0x4030, 0x58D4, 0x58E0, 0x58EC };

pub fn creditsCopy(rom: []const u8, at: u16) ?TitleCopy {
    const o = 5 * offsets.bank_size + (at - 0x4000);
    const b = rom[o..][0..9];
    if (b[0] != 0x01 or b[3] != 0x21 or b[6] != 0x11) return null;
    return .{
        .len = std.mem.readInt(u16, b[1..3], .little),
        .src = std.mem.readInt(u16, b[4..6], .little),
        .dest = std.mem.readInt(u16, b[7..9], .little),
    };
}

/// Rule 3 for the credits: the entry each copy names whose destination is
/// under the objects. Only the entry the copy starts at: the $1000 from
/// `gfx_creditsSprTiles` runs $100 into `gfx_theEnd`, and those land at $8F00
/// under the numbers' copy, which the same pass makes after it.
fn markCreditsObjects(allocator: std.mem.Allocator, rom: []const u8, usage: *std.StringArrayHashMapUnmanaged(Usage)) !void {
    for (credits_copies_at) |at| {
        const c = creditsCopy(rom, at) orelse return Error.UnresolvedSource;
        if (c.dest < 0x8000 or c.dest >= 0x9000) continue;
        const e = for (offsets.entries) |e| {
            if (e.bank == 5 and e.gb_addr == c.src) break e;
        } else return Error.UnresolvedSource;
        const gop = try usage.getOrPut(allocator, e.name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.credits_obj = true;
    }
}

/// Rule 3 for the title's copy: every bank-5 entry the run covers whose
/// destination reaches into the shared window is also object characters.
fn markTitleWindow(allocator: std.mem.Allocator, rom: []const u8, usage: *std.StringArrayHashMapUnmanaged(Usage)) !void {
    const c = titleCopy(rom) orelse return Error.UnresolvedSource;
    for (offsets.entries) |e| {
        if (e.bank != 5 or e.gb_addr < c.src or e.gb_addr >= c.src + c.len) continue;
        const dest = c.dest + (e.gb_addr - c.src);
        if (!target.inSharedWindow(dest)) continue;
        const gop = try usage.getOrPut(allocator, e.name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.title_obj = true;
    }
}

// ---- Metatiles ------------------------------------------------------------

pub const metatile_words: usize = 4;
pub const metatile_bytes: usize = metatile_words * 2;

/// Four tilemap words per metatile, in the same TL TR BL BR order the Game Boy
/// stores its four ids. Tile id `$FF` is carried through like any other: it is
/// a real character that `gfx_commonItems` writes, not a sentinel.
pub fn convertMetatiles(allocator: std.mem.Allocator, gb: []const u8) ![]u8 {
    if (gb.len % tileset.metatile_bytes != 0) return Error.RaggedMetatileTable;
    const n = gb.len / tileset.metatile_bytes;
    const out = try allocator.alloc(u8, n * metatile_bytes);
    errdefer allocator.free(out);
    for (0..n * metatile_words) |i| {
        const w: u16 = @bitCast(target.playWord(gb[i]));
        out[i * 2] = @truncate(w);
        out[i * 2 + 1] = @truncate(w >> 8);
    }
    return out;
}

/// The inverse. Fails if any word carries a bit the converter does not set,
/// which is what makes the round-trip evidence rather than a tautology: a
/// converter that dropped the palette would still round-trip if the inverse
/// dropped it too, but it could not round-trip a word it was handed.
pub fn unconvertMetatiles(allocator: std.mem.Allocator, snes: []const u8) ![]u8 {
    if (snes.len % metatile_bytes != 0) return Error.RaggedMetatileTable;
    const n = snes.len / 2;
    const out = try allocator.alloc(u8, n);
    errdefer allocator.free(out);
    for (0..n) |i| {
        const w: u16 = @as(u16, snes[i * 2]) | (@as(u16, snes[i * 2 + 1]) << 8);
        out[i] = target.tileIdFromWord(@bitCast(w)) orelse return Error.RaggedMetatileTable;
    }
    return out;
}

// ---- Game Boy tilemap fragments -------------------------------------------

/// A Game Boy tilemap is one byte per cell; a SNES tilemap is one word. The
/// conversion is the same `playWord` the metatiles use, so a fragment copied
/// into the map and a metatile drawn into it agree about what a tile id means.
/// The one tilemap whose ids are not read through the play field's character
/// map. See `target.charForTitleId`: the title screen's characters arrive in
/// one 4 KiB copy in VRAM address order, so the ids that index them are rotated
/// by 128 and the tilemap is where that rotation is paid.
pub const title_tilemap = "title_tilemap";
/// And the one whose ids are the window's (1.0 Step 6): the Queen's head, which
/// every door that copies it copies to $9C00 (a test below holds that), so its
/// words are BG2's, `target.windowWord`.
pub const window_tilemap = "bg_queenHead";

pub fn convertTilemap(allocator: std.mem.Allocator, gb: []const u8, name: []const u8) ![]u8 {
    const title = std.mem.eql(u8, name, title_tilemap);
    const window = std.mem.eql(u8, name, window_tilemap);
    const out = try allocator.alloc(u8, gb.len * 2);
    errdefer allocator.free(out);
    for (gb, 0..) |id, i| {
        const w: u16 = @bitCast(if (title) target.titleWord(id) else if (window) target.windowWord(id) else target.playWord(id));
        out[i * 2] = @truncate(w);
        out[i * 2 + 1] = @truncate(w >> 8);
    }
    return out;
}

// ---- Map ------------------------------------------------------------------

/// One grid cell in the runtime map: which screen body, how it scrolls, and the
/// transition index, in four bytes.
///
/// The screen becomes an index into the bank's own 59-body pool rather than the
/// Game Boy's 16-bit address. Index 0 is the shared blank at $4500, which is
/// the same thing `map.Cell.inUse` tests for, so "in use" stays `screen != 0`
/// and no separate flag is needed.
pub const cell_bytes: usize = 4;
pub const screens_per_bank: usize = map.screens_per_bank;

/// The one cell in bank $A holding a null pointer. It is not the blank screen -
/// blank is index 0 - so it needs a value of its own rather than being folded
/// into blank and disappearing.
pub const null_screen: u8 = 0xFF;

pub fn convertBank(allocator: std.mem.Allocator, bank: map.Bank) ![]u8 {
    const out = try allocator.alloc(u8, map.cells * cell_bytes);
    errdefer allocator.free(out);
    for (bank.cells, 0..) |c, i| {
        const slot = out[i * cell_bytes ..][0..cell_bytes];
        slot[0] = if (c.screenOffsetInBank()) |_|
            @intCast((c.screen_ptr - map.screens_addr) / map.screen_bytes)
        else
            null_screen;
        slot[1] = @bitCast(c.scroll);
        slot[2] = @truncate(c.transition);
        slot[3] = @truncate(c.transition >> 8);
    }
    return out;
}

/// The inverse. The Game Boy addresses are reconstructed from the indexes,
/// which is the whole point: if the index arithmetic were wrong, the
/// reconstructed pointers would not match the ROM's.
pub fn unconvertBank(allocator: std.mem.Allocator, snes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, map.cells * 2);
    errdefer allocator.free(out);
    for (0..map.cells) |i| {
        const slot = snes[i * cell_bytes ..][0..cell_bytes];
        const ptr: u16 = if (slot[0] == null_screen)
            0
        else
            map.screens_addr + @as(u16, slot[0]) * @as(u16, map.screen_bytes);
        out[i * 2] = @truncate(ptr);
        out[i * 2 + 1] = @truncate(ptr >> 8);
    }
    return out;
}

// ---- Door scripts ---------------------------------------------------------
//
// The opcode encoding is deliberately unchanged: the high nibble still selects
// the operation and the low nibble still carries the variant, so the runtime
// dispatcher is the same shape as 0:$239C's if-chain. What changes is the
// operands, and only where a Game Boy address cannot mean anything on the SNES:
//
//   COPY   source (bank, address) -> asset id + byte offset
//          VRAM destination       -> absolute VRAM word address
//          length in bytes        -> length in words at the target depth
//          and the Game Boy source rides along after them, unconverted: the
//          original stores it in the save buffer ($D808-$D80C), and a save
//          record the cart writes is the Game Boy's byte for byte (Step 15a)
//   LOAD   source (bank, address) -> asset id
//          destination and length are implicit, as they are on the Game Boy
//   WARP   bank $9-$F             -> map index 0-6
//          operand                -> unchanged, deliberately: Step 7 derived
//                                    that the runtime splits its nibbles into
//                                    row and column itself, and pre-resolving
//                                    would bake in an answer the engine derives
//
// Everything else rides through byte for byte.

/// Size of a converted operation.
///
/// `COPY` is eleven bytes: a u8 asset id and a u16 offset replace a u8 bank
/// and a u16 address, the destination and length stay u16, and the Game Boy's
/// own bank and address follow for the save buffer. A `LOAD` becomes one or two
/// of those. Nothing else changes size at all.
pub const ConvertedScript = struct {
    bytes: []u8,
    /// Byte offset of each script within `bytes`, one per Game Boy pointer.
    starts: []u16,

    pub fn deinit(self: *ConvertedScript, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.starts);
    }
};

/// Resolve a door source to `(asset id, byte offset)` against an id lookup.
const AssetIndex = std.StringArrayHashMapUnmanaged(u8);

/// Asset id to the kind it was converted at, so a source offset can be scaled
/// without re-deriving which depth the id names.
pub const KindIndex = std.AutoHashMapUnmanaged(u8, AssetKind);

fn sourceId(index: AssetIndex, bank: u8, addr: u16) !struct { id: u8, delta: u16 } {
    const resolved = door.resolveSource(bank, addr) orelse return Error.UnresolvedSource;
    const id = index.get(resolved.name) orelse return Error.UnresolvedSource;
    return .{ .id = id, .delta = @intCast(resolved.delta) };
}

fn put8(buf: []u8, i: *usize, v: u8) void {
    buf[i.*] = v;
    i.* += 1;
}

fn put16(buf: []u8, i: *usize, v: u16) void {
    buf[i.*] = @truncate(v);
    buf[i.* + 1] = @truncate(v >> 8);
    i.* += 2;
}

/// The class a converted `COPY` writes into. It occupies the same low nibble
/// the Game Boy used for its source variant, which is dead information once the
/// source is an asset id - so the nibble is reused for the thing the engine
/// actually has to dispatch on: how wide the destination's characters are.
pub const CopyClass = enum(u4) {
    /// Tilemap words, into BG3's tilemap.
    data = 0,
    /// 2bpp characters, into BG3's character region.
    bg = 1,
    /// 4bpp characters, into the object character region.
    obj = 2,
    /// The background half of a `spr` transfer: 2bpp characters, into the same
    /// region `bg` names and by the same route. It is a separate class because
    /// of what it costs rather than where it goes. The Game Boy made this
    /// transfer *once* -- $8B00 is inside the window its objects and its
    /// background share, so one copy served both -- and paid one queue drain
    /// for it. Splitting it in two here must not double the frames the port
    /// waits, so the second half says so in its class and the engine's `.copy`
    /// charges it nothing. See `src/transition.zig`.
    bg_twin = 3,
};

/// How many converted bytes one Game Boy byte of an asset becomes. A source
/// offset is a Game Boy byte offset, so it has to be scaled by this before it
/// can index the converted asset.
fn assetScale(kind: AssetKind) u16 {
    return switch (kind) {
        .chr_bg => 1, // 2bpp is the Game Boy's own 16 bytes per tile
        .chr_obj => 2, // 4bpp doubles it
        .tilemap => 2, // one byte per cell becomes one word
    };
}

fn emitCopy(out: []u8, n: *usize, class: CopyClass, id: u8, offset: u16, dest: u16, words: u16, gb_bank: u8, gb_addr: u16) void {
    put8(out, n, @intFromEnum(class));
    put8(out, n, id);
    put16(out, n, offset);
    put16(out, n, dest);
    put16(out, n, words);
    put8(out, n, gb_bank);
    put16(out, n, gb_addr);
}

/// One converted `COPY`, from the Game Boy's `(source, dest, len)` to the
/// SNES's `(asset id, offset, VRAM word address, word count)`.
///
/// `gb_len` is in Game Boy bytes. What that means in SNES words depends on the
/// destination, not the source: sixteen Game Boy bytes are one character either
/// way, but a character is 8 words at 2bpp and 16 at 4bpp, and a tilemap cell
/// is one byte on the Game Boy and one word here.
fn convertCopy(
    out: []u8,
    n: *usize,
    index: AssetIndex,
    kinds: KindIndex,
    src_bank: u8,
    src_addr: u16,
    class: CopyClass,
    dest_words: u16,
    gb_len: u16,
) !void {
    const src = try sourceId(index, src_bank, src_addr);
    const kind = kinds.get(src.id) orelse return Error.UnresolvedSource;
    const words: u16 = switch (class) {
        .data => gb_len,
        .bg, .bg_twin => gb_len / 2,
        .obj => gb_len,
    };
    emitCopy(out, n, class, src.id, src.delta * assetScale(kind), dest_words, words, src_bank, src_addr);
}

/// Convert one operation, which may become more than one.
///
/// Two Game Boy shapes have no single SNES equivalent, and both are handled
/// here rather than left for the engine:
///
///  1. **A copy into `$8800`-`$8FFF` becomes two copies.** That range is inside
///     the background's signed window *and* inside the object area, and the
///     Game Boy lets one transfer serve both. On the SNES the same pixels have
///     to exist twice, at two depths, in two regions. Every `spr` operation in
///     the retail ROM lands there - 228 `LOAD_spr` and 3 `COPY_spr`, all
///     between `$8B00` and `$9000` - so this is not an edge case, it is what
///     `spr` means. Without it `metatiles_surface`'s id `$EF` and
///     `metatiles_queen`'s `$FE` would address characters nothing ever wrote.
///     **The rule is the destination's, not the opcode's**: three `COPY_DATA
///     gfx_commonItems` land at $8F00 too, and until Step 21 they were made
///     once, so the missile door drew from object characters that were zero.
///  2. **`LOAD` becomes a `COPY`.** The Game Boy opcode carried no operands
///     because the handler at 0:`$26EB` supplied them, and a single implied
///     destination was enough there. It is not enough here: `LOAD_spr`'s one
///     transfer becomes two with different destinations, lengths, and depths.
///     Rather than teach a second opcode to mean two things, the converted
///     stream drops `LOAD` and spells the operands out. `$B0`-`$BF` is
///     unallocated in the converted encoding as a result.
pub fn convertOp(op: door.Op, bg_index: AssetIndex, obj_index: AssetIndex, kinds: KindIndex, out: []u8) !usize {
    var n: usize = 0;
    switch (op) {
        .copy => |c| {
            if (c.which == .spr or target.inSharedWindow(c.dest)) {
                if (c.which == .bg) return Error.SharedWindowBgCopy;
                // The object half is the one the engine charges, `obj` at one
                // Game Boy byte a word -- the same `len` a `bg` copy charges --
                // so the split costs no frame. `COPY_DATA` stores no source
                // (00:$2747), so neither half carries one.
                try convertCopy(out, &n, obj_index, kinds, c.src_bank, c.src_addr, .obj, try target.gbDestToObj(c.dest), c.len);
                if (c.which == .data) out[n - 3] = no_source_bank;
                try convertCopy(out, &n, bg_index, kinds, c.src_bank, c.src_addr, .bg_twin, (try target.gbDestToChar(c.dest)).wordAddr(), c.len);
                if (c.which == .data) out[n - 3] = no_source_bank;
            } else {
                const dest = try target.gbDestToChar(c.dest);
                const class: CopyClass = switch (dest) {
                    .tilemap, .window => .data,
                    .chars => .bg,
                };
                try convertCopy(out, &n, bg_index, kinds, c.src_bank, c.src_addr, class, dest.wordAddr(), c.len);
                // `COPY_DATA` stores no source (00:$2747), so it carries none.
                if (c.which == .data) out[n - 3] = no_source_bank;
            }
        },
        .load => |l| switch (l.which) {
            .bg => try convertCopy(
                out, &n, bg_index, kinds, l.src_bank, l.src_addr, .bg,
                (try target.gbDestToChar(screens.load_bg_dest)).wordAddr(), screens.load_bg_len,
            ),
            .spr => {
                try convertCopy(
                    out, &n, obj_index, kinds, l.src_bank, l.src_addr, .obj,
                    try target.gbDestToObj(screens.load_spr_dest), screens.load_spr_len,
                );
                try convertCopy(
                    out, &n, bg_index, kinds, l.src_bank, l.src_addr, .bg_twin,
                    (try target.gbDestToChar(screens.load_spr_dest)).wordAddr(), screens.load_spr_len,
                );
            },
        },
        .warp => |w| {
            if (w.bank < map.first_bank or w.bank > map.last_bank) return Error.WarpBankOutOfRange;
            put8(out, &n, 0x40 | @as(u8, @intCast(w.bank - map.first_bank)));
            put8(out, &n, w.pos);
        },
        .enter_queen => |q| {
            if (q.bank < map.first_bank or q.bank > map.last_bank) return Error.WarpBankOutOfRange;
            put8(out, &n, 0x80 | @as(u8, @intCast(q.bank - map.first_bank)));
            put16(out, &n, q.scroll_y);
            put16(out, &n, q.scroll_x);
            put16(out, &n, q.samus_y);
            put16(out, &n, q.samus_x);
        },
        // Everything below carries no Game Boy address, so the Game Boy
        // encoder is the conversion.
        else => n = door.encodeOne(op, out),
    }
    return n;
}

/// Converted bytes one Game Boy operation becomes.
pub const copy_bytes: usize = 11;

/// The bank a converted copy carries when the original stores no source for
/// it: `COPY_DATA` (00:$2747 falls through to `loadGraphics`, which stores
/// nothing). No cartridge bank is numbered $FF. Mirrored as `!COPY_NO_SOURCE`.
pub const no_source_bank: u8 = 0xFF;

pub fn convertedSize(op: door.Op) usize {
    return switch (op) {
        // A copy into the shared window becomes two.
        .copy => |c| if (c.which == .spr or target.inSharedWindow(c.dest)) 2 * copy_bytes else copy_bytes,
        .load => |l| switch (l.which) {
            .bg => copy_bytes,
            .spr => 2 * copy_bytes,
        },
        else => op.size(),
    };
}

// ---- The graphics a save record can name ----------------------------------
//
// Step 15b. A load does not replay a door script: `gameMode_LoadB` (00:$0464)
// fills VRAM out of the save buffer, `$800` bytes of background characters from
// `saveBuf_bgGfxSrc*` and `$400` of enemy characters from `saveBuf_enGfxSrc*`
// (`loadGame_loadGraphics`, 00:$05FD). The enemy half is read in
// `gfx_enemiesA`'s bank whatever bank it was written from, because a record
// keeps no bank for it.
//
// A record's sources are written by a door's transfers and by `initialSaveFile`
// and by nothing else, so the transfers below are every source a cart can be
// asked for. Each becomes the `LOAD` the original performs from it, converted the
// way a door's own `LOAD` is.

/// The `LOAD`s, background ones first, each source once.
pub fn loadOps(allocator: std.mem.Allocator, rom: []const u8, ops: []const door.Op) ![]door.Op {
    const enemy_bank = (offsets.find("gfx_enemiesA") orelse return Error.UnresolvedSource).bank;
    const init = save.initial(rom) orelse return Error.UnresolvedSource;

    var bg: std.ArrayList(door.Op) = .empty;
    var spr: std.ArrayList(door.Op) = .empty;
    const put = struct {
        fn put(a: std.mem.Allocator, list: *std.ArrayList(door.Op), op: door.Op) !void {
            for (list.items) |have| {
                if (have.load.src_bank == op.load.src_bank and have.load.src_addr == op.load.src_addr) return;
            }
            try list.append(a, op);
        }
    }.put;

    try put(allocator, &bg, .{ .load = .{ .which = .bg, .src_bank = init.bg_gfx_bank, .src_addr = init.bg_gfx_src } });
    try put(allocator, &spr, .{ .load = .{ .which = .spr, .src_bank = enemy_bank, .src_addr = init.enemy_gfx_src } });
    for (ops) |op| {
        // `door_loadGraphics` (00:$26E3) and `door_copyData`'s two stored
        // variants (00:$2771 `COPY_BG`, 00:$2798 `COPY_SPR`). `COPY_DATA` stores
        // nothing, whatever it copies into.
        const src: struct { which: door.Load, bank: u8, addr: u16 } = switch (op) {
            .load => |l| .{ .which = l.which, .bank = l.src_bank, .addr = l.src_addr },
            .copy => |c| switch (c.which) {
                .bg => .{ .which = .bg, .bank = c.src_bank, .addr = c.src_addr },
                .spr => .{ .which = .spr, .bank = c.src_bank, .addr = c.src_addr },
                .data => continue,
            },
            else => continue,
        };
        switch (src.which) {
            .bg => try put(allocator, &bg, .{ .load = .{ .which = .bg, .src_bank = src.bank, .src_addr = src.addr } }),
            .spr => try put(allocator, &spr, .{ .load = .{ .which = .spr, .src_bank = enemy_bank, .src_addr = src.addr } }),
        }
    }
    return std.mem.concat(allocator, door.Op, &.{ bg.items, spr.items });
}

/// One of the fixed transfers in `loadGame_loadGraphics` (00:$05FD): `LD A,bank
/// / LD ($D04E),A / LD ($2100),A / LD BC,len / LD HL,src / LD DE,dest / CALL
/// copyToVram`. Read off the ROM rather than written down.
pub const LoadCopy = struct { bank: u8, src: u16, dest: u16, len: u16 };

/// The routine's first transfer, the common item tiles to $8F00.
pub const load_common_at: u16 = 0x05FD;
/// And the one it makes only on a load, the item font to $8C00 (00:$063E tests
/// `loadingFromFile` and skips it for a new game).
pub const load_font_at: u16 = 0x0644;

pub fn loadGraphicsCopy(rom: []const u8, at: u16) ?LoadCopy {
    if (at + 20 > rom.len) return null;
    const b = rom[at..][0..20];
    const shape = [_]?u8{ 0x3E, null, 0xEA, 0x4E, 0xD0, 0xEA, 0x00, 0x21, 0x01, null, null, 0x21, null, null, 0x11, null, null, 0xCD, 0x8A, 0x03 };
    for (shape, b) |want, have| {
        if (want) |w| if (w != have) return null;
    }
    return .{
        .bank = b[1],
        .len = std.mem.readInt(u16, b[9..11], .little),
        .src = std.mem.readInt(u16, b[12..14], .little),
        .dest = std.mem.readInt(u16, b[15..17], .little),
    };
}

/// The `ITEM` door opcode's arm, 00:$2618-$26D4, read off the ROM (Step 24).
/// It makes four transfers through `beginGraphicsTransfer` (00:$27BA) and
/// stores no save source for any of them:
///
///  - the item's four tiles, `tile_base + ((op - 1) & $0F) * tile_len`, to
///    `tile_dest`. Sixteen nibbles at $40 apiece span bank 7 from `gfx_items`
///    through `gfx_itemOrb` to the end of `gfx_commonItems`, so a nibble past
///    the eleven items reads those sheets, as on the Game Boy;
///  - the orb, `orb_src` to `orb_dest`;
///  - `font_len` bytes of the item font, $30 more than the load's $200, so
///    three characters past the font;
///  - the item's name, `item_names[op & $0F]`, to `name_dest`. **Not
///    converted** (Step 24 ports the characters, not the window's text). Its
///    length is here because its frame is part of what the opcode costs.
pub const ItemArm = struct {
    bank: u8,
    tile_base: u16,
    tile_len: u16,
    tile_dest: u16,
    orb_src: u16,
    orb_len: u16,
    orb_dest: u16,
    font_bank: u8,
    font_src: u16,
    font_len: u16,
    font_dest: u16,
    name_len: u16,
    name_dest: u16,

    /// Every transfer's length, in the arm's order.
    pub fn lens(self: ItemArm) [4]u16 {
        return .{ self.tile_len, self.orb_len, self.font_len, self.name_len };
    }
};
pub const item_arm_at: u16 = 0x2618;
/// The nibbles an `ITEM` operand can carry.
pub const item_nibbles: usize = 16;

pub fn itemArm(rom: []const u8) ?ItemArm {
    if (item_arm_at + 0xBC > rom.len) return null;
    const b = rom[item_arm_at..][0..0xBC];
    // `LD A,n / LDH ($FFBx),A`, with the operand at `at`.
    const ldh = struct {
        fn f(bytes: []const u8, at: usize, reg: u8) ?u8 {
            if (bytes[at - 1] != 0x3E or bytes[at + 1] != 0xE0 or bytes[at + 2] != reg) return null;
            return bytes[at];
        }
    }.f;
    // `LD A,n / LD ($D04E),A`: the bank switch in front of each group.
    const bank = struct {
        fn f(bytes: []const u8, at: usize) ?u8 {
            if (bytes[at - 1] != 0x3E or !std.mem.eql(u8, bytes[at + 1 ..][0..3], &.{ 0xEA, 0x4E, 0xD0 })) return null;
            return bytes[at];
        }
    }.f;
    const w = struct {
        fn f(lo: ?u8, hi: ?u8) ?u16 {
            return @as(u16, lo orelse return null) | @as(u16, hi orelse return null) << 8;
        }
    }.f;
    for ([_]usize{ 0x38, 0x53, 0x79, 0xB3 }) |at| {
        if (!std.mem.eql(u8, b[at..][0..3], &.{ 0xCD, 0xBA, 0x27 })) return null;
    }
    // `LD A,(HL) / PUSH HL / DEC A / AND $0F / SWAP A`, then two
    // `SLA E / RL D`: the nibble less one, times $40.
    if (!std.mem.eql(u8, b[0x0C..][0..0x12], &.{ 0x7E, 0xE5, 0x3D, 0xE6, 0x0F, 0xCB, 0x37, 0x5F, 0x16, 0x00, 0xCB, 0x23, 0xCB, 0x12, 0xCB, 0x23, 0xCB, 0x12 })) return null;
    if (b[0x1E] != 0x21) return null;
    const arm: ItemArm = .{
        .bank = bank(b, 0x02) orelse return null,
        .tile_base = std.mem.readInt(u16, b[0x1F..][0..2], .little),
        .tile_dest = w(ldh(b, 0x29, 0xB3), ldh(b, 0x2D, 0xB4)) orelse return null,
        .tile_len = w(ldh(b, 0x31, 0xB5), ldh(b, 0x35, 0xB6)) orelse return null,
        .orb_src = w(ldh(b, 0x3C, 0xB1), ldh(b, 0x40, 0xB2)) orelse return null,
        .orb_dest = w(ldh(b, 0x44, 0xB3), ldh(b, 0x48, 0xB4)) orelse return null,
        .orb_len = w(ldh(b, 0x4C, 0xB5), ldh(b, 0x50, 0xB6)) orelse return null,
        .font_bank = bank(b, 0x57) orelse return null,
        .font_src = w(ldh(b, 0x62, 0xB1), ldh(b, 0x66, 0xB2)) orelse return null,
        .font_dest = w(ldh(b, 0x6A, 0xB3), ldh(b, 0x6E, 0xB4)) orelse return null,
        .font_len = w(ldh(b, 0x72, 0xB5), ldh(b, 0x76, 0xB6)) orelse return null,
        .name_dest = w(ldh(b, 0xA4, 0xB3), ldh(b, 0xA8, 0xB4)) orelse return null,
        .name_len = w(ldh(b, 0xAC, 0xB5), ldh(b, 0xB0, 0xB6)) orelse return null,
    };
    // The index is scaled by $40, so a transfer of any other length would
    // overlap the next item's or leave a gap. The ROM's is $40.
    if (arm.tile_len != 0x40) return null;
    return arm;
}

/// The Game Boy bytes the tile transfers can read: every nibble's window.
pub fn itemWindowLen(arm: ItemArm) usize {
    return item_nibbles * @as(usize, arm.tile_len);
}

/// The two prelude copies and the background and enemy entries' offsets in the
/// blob, mirrored as the engine's `!LS_*`.
pub const load_prelude_at: usize = 2;
pub const load_font_entry_at: usize = load_prelude_at + 2 * copy_bytes;
/// `ITEM`'s transfers (Step 24): the orb's two copies, the font's two, and
/// then two per nibble for the item's tiles.
pub const load_item_at: usize = load_font_entry_at + 2 * copy_bytes;
pub const load_item_tiles_at: usize = load_item_at + 4 * copy_bytes;
pub const load_entries_at: usize = load_item_tiles_at + 2 * item_nibbles * copy_bytes;
/// The window assets `ITEM`'s transfers read.
const item_window_name = "item_window";
const item_font_name = "item_font";

/// The doors class's `load_sources` blob: a background count and an enemy
/// count; the load's two fixed transfers, the common item tiles and the item
/// font (two copies each, since $8F00 and $8C00 are both in the window objects
/// and background share); `ITEM`'s transfers (`load_item_at`), which the door
/// interpreter's `.item` reads from here; then each background `LOAD`
/// converted (`copy_bytes`) and each enemy one (two copies). The engine finds an entry by the Game Boy source every
/// converted copy already carries at its bytes 8-10.
fn loadSources(
    allocator: std.mem.Allocator,
    rom: []const u8,
    loads: []const door.Op,
    bg_index: AssetIndex,
    obj_index: AssetIndex,
    kinds: KindIndex,
) ![]u8 {
    var bg_n: usize = 0;
    var bytes: usize = load_entries_at;
    for (loads) |op| {
        if (op.load.which == .bg) bg_n += 1;
        bytes += convertedSize(op);
    }
    if (bg_n > 0xFF or loads.len - bg_n > 0xFF) return Error.TooManyAssets;
    const out = try allocator.alloc(u8, bytes);
    out[0] = @intCast(bg_n);
    out[1] = @intCast(loads.len - bg_n);
    var n: usize = load_prelude_at;

    // Neither stores a source, so neither carries one.
    const common = loadGraphicsCopy(rom, load_common_at) orelse return Error.UnresolvedSource;
    // Into the shared window, so two, as a door's `COPY_DATA` there converts.
    try convertCopy(out, &n, obj_index, kinds, common.bank, common.src, .obj, try target.gbDestToObj(common.dest), common.len);
    out[n - 3] = no_source_bank;
    try convertCopy(out, &n, bg_index, kinds, common.bank, common.src, .bg_twin, (try target.gbDestToChar(common.dest)).wordAddr(), common.len);
    out[n - 3] = no_source_bank;
    const font = loadGraphicsCopy(rom, load_font_at) orelse return Error.UnresolvedSource;
    emitCopy(out, &n, .obj, obj_index.get(load_font_name).?, 0, try target.gbDestToObj(font.dest), font.len, no_source_bank, font.src);
    try convertCopy(out, &n, bg_index, kinds, font.bank, font.src, .bg_twin, (try target.gbDestToChar(font.dest)).wordAddr(), font.len);
    out[n - 3] = no_source_bank;

    // `ITEM`'s three character transfers (Step 24), each into the shared
    // window and so two copies, and none storing a source: the orb, the font,
    // then the item's tiles once per nibble.
    std.debug.assert(n == load_item_at);
    const arm = itemArm(rom) orelse return Error.UnresolvedSource;
    const Pair = struct {
        fn emit(o: []u8, i: *usize, obj: u8, bg: u8, delta: u16, dest: u16, len: u16, src: u16) !void {
            if (!target.inSharedWindow(dest)) return Error.UnresolvedSource;
            emitCopy(o, i, .obj, obj, delta * assetScale(.chr_obj), try target.gbDestToObj(dest), len, no_source_bank, src);
            emitCopy(o, i, .bg_twin, bg, delta * assetScale(.chr_bg), (try target.gbDestToChar(dest)).wordAddr(), len / 2, no_source_bank, src);
        }
    };
    const win_obj = obj_index.get(item_window_name).?;
    const win_bg = bg_index.get(item_window_name).?;
    try Pair.emit(out, &n, win_obj, win_bg, arm.orb_src - arm.tile_base, arm.orb_dest, arm.orb_len, arm.orb_src);
    try Pair.emit(out, &n, obj_index.get(item_font_name).?, bg_index.get(item_font_name).?, 0, arm.font_dest, arm.font_len, arm.font_src);
    std.debug.assert(n == load_item_tiles_at);
    for (0..item_nibbles) |nib| {
        // 00:$2626: the operand less one, so nibble 0 (a save station) reads
        // the sixteenth window.
        const delta: u16 = @intCast(((nib + item_nibbles - 1) % item_nibbles) * arm.tile_len);
        try Pair.emit(out, &n, win_obj, win_bg, delta, arm.tile_dest, arm.tile_len, arm.tile_base + delta);
    }
    std.debug.assert(n == load_entries_at);

    for (loads) |op| {
        if (loadWindow(op) == null) {
            n += try convertOp(op, bg_index, obj_index, kinds, out[n..]);
            continue;
        }
        const name = try loadWindowName(allocator, op);
        const l = op.load;
        switch (l.which) {
            .bg => emitCopy(out, &n, .bg, bg_index.get(name).?, 0, (try target.gbDestToChar(screens.load_bg_dest)).wordAddr(), screens.load_bg_len / 2, l.src_bank, l.src_addr),
            .spr => {
                emitCopy(out, &n, .obj, obj_index.get(name).?, 0, try target.gbDestToObj(screens.load_spr_dest), screens.load_spr_len, l.src_bank, l.src_addr);
                emitCopy(out, &n, .bg_twin, bg_index.get(name).?, 0, (try target.gbDestToChar(screens.load_spr_dest)).wordAddr(), screens.load_spr_len / 2, l.src_bank, l.src_addr);
            },
        }
    }
    std.debug.assert(n == bytes);
    return out;
}

/// Where a load reads from, if no asset starts on a tile boundary under it.
///
/// Four enemy sources do not. `gfx_metAlpha`, `gfx_metGamma`, `gfx_metZeta` and
/// `gfx_metOmega` are loaded from bank 8 and read back in bank 6, `$9C` into a
/// sheet there, and `gfx_queenSPR` (8:$79BC) past the last one. The Game Boy
/// copies the bytes anyway, so the port converts exactly those bytes.
fn loadWindow(op: door.Op) ?usize {
    const l = op.load;
    const at = @as(usize, l.src_bank) * offsets.bank_size + (l.src_addr & 0x3FFF);
    const src = door.resolveSource(l.src_bank, l.src_addr) orelse return at;
    return if (src.delta % gfx.tile_bytes == 0) null else at;
}

/// The item font's object sheet. Nothing else loads the font as objects, so it
/// has no asset from the survey; its background half is the title's.
const load_font_name = "load_font";

fn loadWindowName(allocator: std.mem.Allocator, op: door.Op) ![]const u8 {
    return std.fmt.allocPrint(allocator, "load_{X}_{X:0>4}", .{ op.load.src_bank, op.load.src_addr });
}

// ---- The whole converted set ----------------------------------------------

pub const Set = struct {
    arena: std.heap.ArenaAllocator,

    assets: []Asset,
    /// The ten metatile tables in **ROM order**, so concatenating them
    /// reproduces the Game Boy's one contiguous region. That is still not
    /// `screens.tiletable_order`, so a `TILETABLE` operand cannot index this
    /// slice - use `snes_render.tables`, which records where each slot starts
    /// within the concatenation.
    metatiles: []Blob,
    collision: []Blob,
    solidity: Blob,
    /// Seven banks of 256 four-byte cells.
    map_cells: []Blob,
    /// Seven banks of 59 screen bodies, 256 metatile indexes each.
    map_screens: []Blob,
    doors: Blob,
    door_pointers: Blob,
    /// The doors class's second blob: every graphics source a save record can
    /// name, as the converted `LOAD` the original's load performs from it. See
    /// `loadSources`.
    load_sources: Blob,
    /// The three arcs in `physics.Which` order, so a blob's index is its id.
    physics: []Blob,
    /// Samus's metasprite set and the pose sprite-id tables, in
    /// `sprites.Which` order, so a blob's index is its id.
    metasprites: []Blob,
    /// The spawn lists and the relocated pointer table, in `EnemyBlob` order,
    /// so a blob's index is its id.
    enemies: []Blob,
    /// The SPC700's ARAM image as upload blocks, in address order: each blob
    /// is the block's ARAM address, little-endian, then its bytes. Built from
    /// the ROM and `engine/audio.bin` by `aram_image`, which is the only thing
    /// that decides a placement. metroid2-audio Step 16a.
    aram: []Blob,
    /// "Super" on the title, Step 24j, in `title_super` order: characters,
    /// palette, map patch, so a blob's index is its id. Not the ROM's.
    title_art: []Blob = &.{},
    /// The debug menu's lists, 1.0 Steps 4 and 5b, in `debug_tables.Which` order.
    debug: []Blob = &.{},
    /// The gfxInfo records `loadGraphics` walks, 1.0 Step 8a, which
    /// `snes_inject` writes into the engine's `GfxInfo` table once each
    /// sheet's asset id is known.
    gfx_info: ?gfx_info.Table = null,

    /// How many assets rest on each basis, so the weakest rule's reach is a
    /// number rather than a footnote.
    by_basis: [3]usize,

    pub fn deinit(self: *Set) void {
        self.arena.deinit();
    }

    pub fn assetById(self: Set, id: u8) ?Asset {
        for (self.assets) |a| {
            if (a.id == id) return a;
        }
        return null;
    }
};

pub const Blob = struct {
    name: []const u8,
    bytes: []u8,
};

/// Convert everything, with the crawl `zig build crawl` cached for this ROM.
/// The returned `Set` owns an arena; `deinit` frees it all.
pub fn run(gpa: std.mem.Allocator, rom: []const u8) !Set {
    const walked = try warp.loadWalked(gpa, rom);
    defer gpa.free(walked);
    return runWalked(gpa, rom, walked);
}

/// `run` with the crawl given (release Step 3): the builder crawls in memory
/// and never reads `build-out/`. Only the debug menu's WARP page reads it.
pub fn runWalked(gpa: std.mem.Allocator, rom: []const u8, walked: []const warp.WalkedDoor) !Set {
    var set: Set = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .assets = &.{},
        .metatiles = &.{},
        .collision = &.{},
        .solidity = .{ .name = "solidity", .bytes = &.{} },
        .map_cells = &.{},
        .map_screens = &.{},
        .doors = .{ .name = "doors", .bytes = &.{} },
        .door_pointers = .{ .name = "door_pointers", .bytes = &.{} },
        .load_sources = .{ .name = "load_sources", .bytes = &.{} },
        .physics = &.{},
        .metasprites = &.{},
        .enemies = &.{},
        .aram = &.{},
        .by_basis = @splat(0),
    };
    errdefer set.arena.deinit();
    const a = set.arena.allocator();

    // ---- Door scripts, decoded once and used three times -------------------
    // The usage survey, the asset table, and the converted stream all read the
    // same decode, so they cannot disagree about what the scripts say.
    const door_entry = offsets.find("door_data") orelse return Error.UnresolvedSource;
    const door_bytes = rom[door_entry.romOffset()..door_entry.romEnd()];
    var decoded = try door.decodeRegion(a, door_bytes);
    defer decoded.deinit(a);

    // The loads a save record can ask for are surveyed with the scripts, so an
    // asset a script copies part of is long enough for the `$800` a load reads.
    const loads = try loadOps(a, rom, decoded.ops.items);
    var on_tiles: std.ArrayList(door.Op) = .empty;
    for (loads) |op| if (loadWindow(op) == null) try on_tiles.append(a, op);
    var usage = try surveyUsage(a, try std.mem.concat(a, door.Op, &.{ decoded.ops.items, on_tiles.items }));
    defer usage.deinit(a);
    try markTitleWindow(a, rom, &usage);
    try markCreditsObjects(a, rom, &usage);

    // ---- Assets ------------------------------------------------------------
    var assets: std.ArrayList(Asset) = .empty;
    var bg_index: AssetIndex = .empty;
    var obj_index: AssetIndex = .empty;
    var kinds: KindIndex = .empty;
    defer bg_index.deinit(a);
    defer obj_index.deinit(a);
    defer kinds.deinit(a);

    var next_id: usize = 0;
    for (offsets.entries) |e| {
        const u = usage.get(e.name) orelse Usage{};
        // As long as the entry, or as long as the door scripts actually read -
        // whichever is more. See `Usage.read_end`.
        const end = @max(e.romEnd(), e.romOffset() + u.read_end);
        if (end > rom.len) continue;
        const gb = rom[e.romOffset()..end];
        for ([_]AssetKind{ .chr_bg, .chr_obj, .tilemap }) |kind| {
            const basis = basisFor(e.kind, u, kind) orelse continue;
            if (next_id > std.math.maxInt(u8)) return Error.TooManyAssets;
            const id: u8 = @intCast(next_id);
            next_id += 1;
            const bytes = switch (kind) {
                .chr_bg => try chr.to2bpp(a, gb),
                .chr_obj => try chr.to4bpp(a, gb),
                .tilemap => try convertTilemap(a, gb, e.name),
            };
            try assets.append(a, .{
                .id = id,
                .name = e.name,
                .kind = kind,
                .basis = basis,
                .rom_at = e.romOffset(),
                .gb_bytes = gb.len,
                .bytes = bytes,
            });
            set.by_basis[@intFromEnum(basis)] += 1;
            try kinds.put(a, id, kind);
            switch (kind) {
                // A tilemap fragment is only ever a `COPY_data` target, so it
                // belongs in the index a non-`spr` copy looks in.
                .chr_bg, .tilemap => try bg_index.put(a, e.name, id),
                .chr_obj => try obj_index.put(a, e.name, id),
            }
        }
    }
    // And a load that lands between tiles, as an asset of its own: the bytes
    // the Game Boy copies, cut every sixteen the way VRAM cuts them.
    for (loads) |op| {
        const at = loadWindow(op) orelse continue;
        const len: usize = switch (op.load.which) {
            .bg => screens.load_bg_len,
            .spr => screens.load_spr_len,
        };
        if (at + len > rom.len) return Error.UnresolvedSource;
        const gb = rom[at..][0..len];
        const name = try loadWindowName(a, op);
        const want: []const AssetKind = switch (op.load.which) {
            .bg => &.{.chr_bg},
            .spr => &.{ .chr_obj, .chr_bg },
        };
        for (want) |kind| {
            if (next_id > std.math.maxInt(u8)) return Error.TooManyAssets;
            const id: u8 = @intCast(next_id);
            next_id += 1;
            try assets.append(a, .{
                .id = id,
                .name = name,
                .kind = kind,
                .basis = .door_op,
                .rom_at = at,
                .gb_bytes = gb.len,
                .bytes = switch (kind) {
                    .chr_obj => try chr.to4bpp(a, gb),
                    else => try chr.to2bpp(a, gb),
                },
            });
            set.by_basis[@intFromEnum(Basis.door_op)] += 1;
            try kinds.put(a, id, kind);
            switch (kind) {
                .chr_obj => try obj_index.put(a, name, id),
                else => try bg_index.put(a, name, id),
            }
        }
    }
    {
        const font = loadGraphicsCopy(rom, load_font_at) orelse return Error.UnresolvedSource;
        const at = @as(usize, font.bank) * offsets.bank_size + (font.src & 0x3FFF);
        if (next_id > std.math.maxInt(u8)) return Error.TooManyAssets;
        const id: u8 = @intCast(next_id);
        next_id += 1;
        try assets.append(a, .{
            .id = id,
            .name = load_font_name,
            .kind = .chr_obj,
            .basis = .door_op,
            .rom_at = at,
            .gb_bytes = font.len,
            .bytes = try chr.to4bpp(a, rom[at..][0..font.len]),
        });
        set.by_basis[@intFromEnum(Basis.door_op)] += 1;
        try kinds.put(a, id, .chr_obj);
        try obj_index.put(a, load_font_name, id);
    }
    // `ITEM`'s two sources (Step 24), as windows of their own: the bytes its
    // tile and orb transfers can read, which cross three offsets entries, and
    // the font as long as `ITEM` copies it. Both at both depths, since every
    // destination is in the shared window.
    {
        const arm = itemArm(rom) orelse return Error.UnresolvedSource;
        const windows = [_]struct { name: []const u8, bank: u8, src: u16, len: usize }{
            .{ .name = item_window_name, .bank = arm.bank, .src = arm.tile_base, .len = itemWindowLen(arm) },
            .{ .name = item_font_name, .bank = arm.font_bank, .src = arm.font_src, .len = arm.font_len },
        };
        for (windows) |win| {
            const at = @as(usize, win.bank) * offsets.bank_size + (win.src & 0x3FFF);
            if (at + win.len > rom.len) return Error.UnresolvedSource;
            const gb = rom[at..][0..win.len];
            for ([_]AssetKind{ .chr_obj, .chr_bg }) |kind| {
                if (next_id > std.math.maxInt(u8)) return Error.TooManyAssets;
                const id: u8 = @intCast(next_id);
                next_id += 1;
                try assets.append(a, .{
                    .id = id,
                    .name = win.name,
                    .kind = kind,
                    .basis = .door_op,
                    .rom_at = at,
                    .gb_bytes = gb.len,
                    .bytes = switch (kind) {
                        .chr_obj => try chr.to4bpp(a, gb),
                        else => try chr.to2bpp(a, gb),
                    },
                });
                set.by_basis[@intFromEnum(Basis.door_op)] += 1;
                try kinds.put(a, id, kind);
                switch (kind) {
                    .chr_obj => try obj_index.put(a, win.name, id),
                    else => try bg_index.put(a, win.name, id),
                }
            }
        }
    }
    set.assets = try assets.toOwnedSlice(a);

    // ---- Tileset tables ----------------------------------------------------
    var metatiles: std.ArrayList(Blob) = .empty;
    var collision: std.ArrayList(Blob) = .empty;
    for (tileset.tilesets) |ts| {
        for (ts.metatiles) |name| {
            const gb = tileset.slice(rom, name) orelse return Error.UnresolvedSource;
            try metatiles.append(a, .{ .name = name, .bytes = try convertMetatiles(a, gb) });
        }
    }
    // Collision blobs go in *operand* order, so that `FindBlob(!CLASS_COLLISION,
    // operand)` in the engine's `.collision` handler resolves to the table the
    // original's handler resolves to. The Game Boy indexes a pointer table
    // rather than the region, and the region is not laid out in operand order:
    // `collision_finalLab` sits in front of the other seven. Resolving through
    // `tileset.collisionOrder` is what makes the operand mean the same thing on
    // both machines, and it is address-driven -- which is why the naming defect
    // fixed on 2026-09-08 never reached a cart.
    const order = tileset.collisionOrder(rom) orelse return Error.UnresolvedSource;
    for (order) |ts_index| {
        const ts = tileset.tilesets[ts_index];
        const gb = tileset.slice(rom, ts.collision) orelse return Error.UnresolvedSource;
        try collision.append(a, .{ .name = ts.collision, .bytes = try a.dupe(u8, gb) });
    }
    // ROM order, not `tileset.tilesets` order. The ten Game Boy tables are one
    // contiguous region and a screen may index off the end of its own table
    // into the next - the three equal-sized `lavaCaves` windows exist for
    // exactly that - so the converted region has to be the concatenation, in
    // the same order, or the bytes past a table's end would be padding instead
    // of the next table. `snes_layout` places this class as one contiguous run
    // for the same reason.
    const metatile_blobs = try metatiles.toOwnedSlice(a);
    std.mem.sort(Blob, metatile_blobs, {}, struct {
        fn lt(_: void, x: Blob, y: Blob) bool {
            const ex = offsets.find(x.name) orelse return false;
            const ey = offsets.find(y.name) orelse return false;
            return ex.romOffset() < ey.romOffset();
        }
    }.lt);
    set.metatiles = metatile_blobs;
    set.collision = try collision.toOwnedSlice(a);
    set.solidity = .{
        .name = "solidity_thresholds",
        .bytes = try a.dupe(u8, tileset.slice(rom, "solidity_thresholds") orelse return Error.UnresolvedSource),
    };

    // ---- Map ---------------------------------------------------------------
    var cells: std.ArrayList(Blob) = .empty;
    var screen_blobs: std.ArrayList(Blob) = .empty;
    for (map.first_bank..map.last_bank + 1) |b| {
        const bank: u8 = @intCast(b);
        var parsed = try map.parseBank(a, rom, bank);
        defer parsed.deinit(a);
        try cells.append(a, .{
            .name = try std.fmt.allocPrint(a, "map{X}_cells", .{bank}),
            .bytes = try convertBank(a, parsed),
        });
        // Screen bodies are metatile indexes and stay exactly that. Every body
        // is carried, referenced or not, for the same reason `map.parseScreens`
        // walks by position: an unreferenced body is still data, and dropping
        // it would make the round-trip a claim about the subset we kept.
        const base = @as(usize, bank) * offsets.bank_size + (map.screens_addr & 0x3FFF);
        try screen_blobs.append(a, .{
            .name = try std.fmt.allocPrint(a, "map{X}_screens", .{bank}),
            .bytes = try a.dupe(u8, rom[base..][0 .. screens_per_bank * map.screen_bytes]),
        });
    }
    set.map_cells = try cells.toOwnedSlice(a);
    set.map_screens = try screen_blobs.toOwnedSlice(a);

    // ---- Door scripts ------------------------------------------------------
    var stream: std.ArrayList(u8) = .empty;
    // Where each Game Boy op offset ended up, so the pointer table can be
    // rewritten without re-walking the stream.
    var moved: std.AutoHashMapUnmanaged(u16, u16) = .empty;
    defer moved.deinit(a);
    // Two eleven-byte copies is the most one Game Boy op becomes.
    var scratch: [2 * copy_bytes]u8 = undefined;
    for (decoded.ops.items, decoded.starts.items) |op, start| {
        try moved.put(a, start, @intCast(stream.items.len));
        const n = try convertOp(op, bg_index, obj_index, kinds, &scratch);
        std.debug.assert(n == convertedSize(op));
        try stream.appendSlice(a, scratch[0..n]);
    }
    // The one offset past the end, which the 14 empty scripts point at.
    try moved.put(a, @intCast(door_bytes.len), @intCast(stream.items.len));
    set.doors = .{ .name = "doors", .bytes = try stream.toOwnedSlice(a) };

    const ptr_entry = offsets.find("door_pointers") orelse return Error.UnresolvedSource;
    const gb_ptrs = rom[ptr_entry.romOffset()..ptr_entry.romEnd()];
    const out_ptrs = try a.alloc(u8, door.pointer_count * 2);
    for (0..door.pointer_count) |i| {
        const gb_addr: u16 = @as(u16, gb_ptrs[i * 2]) | (@as(u16, gb_ptrs[i * 2 + 1]) << 8);
        // A pointer outside the script region cannot be relocated - there is
        // exactly one, into bank 5 freespace at $7F34, and Step 4 already
        // accounts for it. It becomes the end-of-stream offset, which is what
        // the 14 empty scripts already use, so it reads as an empty script
        // rather than as a wild jump.
        const rel: u16 = if (gb_addr >= door.data_addr and gb_addr <= door.data_end)
            gb_addr - door.data_addr
        else
            @intCast(door_bytes.len);
        const new = moved.get(rel) orelse @as(u16, @intCast(set.doors.bytes.len));
        out_ptrs[i * 2] = @truncate(new);
        out_ptrs[i * 2 + 1] = @truncate(new >> 8);
    }
    set.door_pointers = .{ .name = "door_pointers", .bytes = out_ptrs };
    set.load_sources = .{ .name = "load_sources", .bytes = try loadSources(a, rom, loads, bg_index, obj_index, kinds) };

    // ---- Physics -----------------------------------------------------------
    // The arcs convert by dropping the terminator, which is the one byte in
    // them that is not a speed. Re-encoding is checked here rather than only in
    // `roundtrip.zig` because the converted blob is what the cart runs on: if
    // the parse were reading the table one byte over, the speeds would still be
    // plausible and only the terminator's position would say so.
    const phys = try a.alloc(Blob, physics.which_count);
    for (0..physics.which_count) |i| {
        const which: physics.Which = @enumFromInt(i);
        const e = offsets.find(which.entry()) orelse return Error.UnresolvedSource;
        const gb = rom[e.romOffset()..e.romEnd()];
        const bytes = if (which.isArc()) blk: {
            const arc = try physics.parseArc(a, gb);
            const back = try physics.encodeArc(a, arc);
            if (!std.mem.eql(u8, back, gb)) return Error.ArcDoesNotReencode;
            break :blk @as([]u8, @ptrCast(arc.speeds));
        } else blk: {
            // Geometry: carried unchanged, but still parsed, because the parse
            // is what says the stride is eight and the terminator lands where
            // the unrolled reader can reach it.
            if (which == .hitbox_y_offsets) {
                const rows = try physics.parseYOffsets(gb);
                const back = physics.encodeYOffsets(rows);
                if (!std.mem.eql(u8, &back, gb)) return Error.ArcDoesNotReencode;
            }
            break :blk try a.dupe(u8, gb);
        };
        phys[i] = .{ .name = which.entry(), .bytes = bytes };
    }
    set.physics = phys;

    // ---- Metasprites -------------------------------------------------------
    // Two things go into the cart and one of them is converted. The records
    // are carried in the Game Boy's own shape - four bytes a part, `$FF` at the
    // end - because turning a part into a SNES OAM entry needs the play
    // window's position on a 256x224 frame, which is the engine's business and
    // not a property of the sprite. The pointer table is the conversion: the
    // ROM stores absolute bank-1 addresses, and what ships is a byte offset
    // into the data blob.
    //
    // The record walk is not just there to produce a length. It is what
    // `sprites.parsePointers` checks every pointer against, so a pointer that
    // lands inside a part rather than on one is refused here rather than drawn
    // on a console.
    const ms = try a.alloc(Blob, sprites.which_count);
    {
        const data_e = offsets.find("metasprite_samus_data") orelse return Error.UnresolvedSource;
        const data_gb = rom[data_e.romOffset()..data_e.romEnd()];
        const records = try entity.parseMetasprites(a, data_gb, data_e.gb_addr);
        const back = try entity.encodeMetasprites(a, records);
        if (!std.mem.eql(u8, back, data_gb)) return Error.MetaspriteDoesNotReencode;

        const ptr_e = offsets.find("metasprite_samus_pointers") orelse return Error.UnresolvedSource;
        const offs = try sprites.parsePointers(
            a,
            rom[ptr_e.romOffset()..ptr_e.romEnd()],
            data_e.gb_addr,
            data_gb.len,
            records,
        );

        // And the enemy set, through exactly the same three steps -- walk the
        // records, re-encode them, resolve the pointer table against the walk.
        // Written out a second time rather than looped, because the two sets
        // are two `Which` pairs and a loop over pairs would be a third shape to
        // read; the checks are the same ones and they refuse the same things.
        const en_data_e = offsets.find("metasprite_enemies_data") orelse return Error.UnresolvedSource;
        const en_data_gb = rom[en_data_e.romOffset()..en_data_e.romEnd()];
        const en_records = try entity.parseMetasprites(a, en_data_gb, en_data_e.gb_addr);
        const en_back = try entity.encodeMetasprites(a, en_records);
        if (!std.mem.eql(u8, en_back, en_data_gb)) return Error.MetaspriteDoesNotReencode;

        const en_ptr_e = offsets.find("metasprite_enemies_pointers") orelse return Error.UnresolvedSource;
        const en_offs = try sprites.parsePointers(
            a,
            rom[en_ptr_e.romOffset()..en_ptr_e.romEnd()],
            en_data_e.gb_addr,
            en_data_gb.len,
            en_records,
        );

        // And the credits set, Step 24h's, the same way again.
        const cr_data_e = offsets.find("metasprite_credits_data") orelse return Error.UnresolvedSource;
        const cr_data_gb = rom[cr_data_e.romOffset()..cr_data_e.romEnd()];
        const cr_records = try entity.parseMetasprites(a, cr_data_gb, cr_data_e.gb_addr);
        const cr_back = try entity.encodeMetasprites(a, cr_records);
        if (!std.mem.eql(u8, cr_back, cr_data_gb)) return Error.MetaspriteDoesNotReencode;

        const cr_ptr_e = offsets.find("metasprite_credits_pointers") orelse return Error.UnresolvedSource;
        const cr_offs = try sprites.parsePointers(
            a,
            rom[cr_ptr_e.romOffset()..cr_ptr_e.romEnd()],
            cr_data_e.gb_addr,
            cr_data_gb.len,
            cr_records,
        );

        for (0..sprites.which_count) |i| {
            const which: sprites.Which = @enumFromInt(i);
            ms[i] = .{
                .name = which.entry(),
                .bytes = switch (which) {
                    .samus_pointers => try sprites.encodePointers(a, offs),
                    .samus_data => try a.dupe(u8, data_gb),
                    .enemies_pointers => try sprites.encodePointers(a, en_offs),
                    .enemies_data => try a.dupe(u8, en_data_gb),
                    .credits_pointers => try sprites.encodePointers(a, cr_offs),
                    .credits_data => try a.dupe(u8, cr_data_gb),
                    else => blk: {
                        const e = offsets.find(which.entry()) orelse return Error.UnresolvedSource;
                        const gb = rom[e.romOffset()..e.romEnd()];
                        // Parsed for the same reason the hitbox tables are:
                        // the parse is what says the row width is four.
                        const t = try sprites.parsePoseTable(a, gb);
                        const enc = try sprites.encodePoseTable(a, t);
                        if (!std.mem.eql(u8, enc, gb)) return Error.MetaspriteDoesNotReencode;
                        break :blk enc;
                    },
                },
            };
        }
    }
    set.metasprites = ms;

    // ---- Enemy spawn lists -------------------------------------------------
    // The same two-blob shape as the door scripts and for the same reason: the
    // records ship in the Game Boy's own form and the *pointers* are the
    // conversion, because a bank-3 address means nothing on a SNES cart.
    //
    // Unlike the doors, no relocation table is needed. Every one of the 1792
    // pointers lands on a list start and the table is in the walk's own order -
    // measured here rather than assumed, by requiring the walk to produce
    // exactly `spawn_lists` lists and each pointer to equal its list's address.
    // A pointer that landed inside a record would fail that, which is what
    // makes the pointer blob a conversion rather than a copy.
    {
        const data_e = offsets.find("enemy_data") orelse return Error.UnresolvedSource;
        const data_gb = rom[data_e.romOffset()..data_e.romEnd()];
        const lists = try entity.parseSpawnLists(a, data_gb, data_e.gb_addr);
        const back = try entity.encodeSpawnLists(a, lists);
        if (!std.mem.eql(u8, back, data_gb)) return Error.SpawnListDoesNotReencode;
        if (lists.len != entity.spawn_lists) return entity.Error.SpawnListCountMismatch;

        var starts: std.AutoHashMapUnmanaged(u16, u16) = .empty;
        defer starts.deinit(a);
        var off: u16 = 0;
        for (lists) |l| {
            try starts.put(a, l.gb_addr, off);
            off += @intCast(l.encoded_len);
        }

        const ptr_e = offsets.find("enemy_data_pointers") orelse return Error.UnresolvedSource;
        const ptr_gb = rom[ptr_e.romOffset()..ptr_e.romEnd()];
        const out = try a.alloc(u8, entity.spawn_lists * 2);
        for (0..entity.spawn_lists) |i| {
            const gb_addr: u16 = @as(u16, ptr_gb[i * 2]) | (@as(u16, ptr_gb[i * 2 + 1]) << 8);
            const rel = starts.get(gb_addr) orelse return Error.SpawnPointerOffAList;
            out[i * 2] = @truncate(rel);
            out[i * 2 + 1] = @truncate(rel >> 8);
        }

        // The headers, and their pointer table relocated the same way. The
        // records are fixed 11-byte rows, so the offset a pointer becomes is
        // derived from the row it lands on rather than searched for - and a
        // pointer that lands between rows is refused, which is the check the
        // fixed stride makes possible and the spawn lists' walk cannot.
        const hdr_e = offsets.find("enemy_headers") orelse return Error.UnresolvedSource;
        const hdr_gb = rom[hdr_e.romOffset()..hdr_e.romEnd()];
        const headers = try entity.parseHeaders(a, hdr_gb);
        const hdr_back = try entity.encodeHeaders(a, headers);
        if (!std.mem.eql(u8, hdr_back, hdr_gb)) return Error.HeaderDoesNotReencode;

        const hptr_e = offsets.find("enemy_header_pointers") orelse return Error.UnresolvedSource;
        const hptr_gb = rom[hptr_e.romOffset()..hptr_e.romEnd()];
        const hout = try a.alloc(u8, entity.enemy_id_space * 2);
        for (0..entity.enemy_id_space) |i| {
            const gb_addr: u16 = @as(u16, hptr_gb[i * 2]) | (@as(u16, hptr_gb[i * 2 + 1]) << 8);
            if (gb_addr < hdr_e.gb_addr or gb_addr >= hdr_e.gb_addr + hdr_gb.len) {
                return Error.HeaderPointerOutOfRange;
            }
            const rel = gb_addr - hdr_e.gb_addr;
            if (rel % entity.header_bytes != 0) return Error.HeaderPointerOffARecord;
            hout[i * 2] = @truncate(rel);
            hout[i * 2 + 1] = @truncate(rel >> 8);
        }

        // The hitboxes, relocated the same way and with one difference that is
        // the finding rather than an exception: 254 of the 255 pointers land on
        // a four-byte record in the region and id $9A's does not - it is
        // $C360, a WRAM address, so there is nothing to point at. It becomes
        // `entity.dead_pointer`, which `HitboxFor` refuses by value. Refusing
        // the *whole conversion* would be the wrong call: the ROM ships that
        // byte and a builder that will not build the retail cartridge is not a
        // builder.
        const hb_e = offsets.find("enemy_hitboxes") orelse return Error.UnresolvedSource;
        const hb_gb = rom[hb_e.romOffset()..hb_e.romEnd()];
        const boxes = try entity.parseHitboxes(a, hb_gb);
        const hb_back = try entity.encodeHitboxes(a, boxes);
        if (!std.mem.eql(u8, hb_back, hb_gb)) return Error.HitboxDoesNotReencode;

        const xptr_e = offsets.find("enemy_hitbox_pointers") orelse return Error.UnresolvedSource;
        const xptr_gb = rom[xptr_e.romOffset()..xptr_e.romEnd()];
        const xout = try a.alloc(u8, entity.enemy_id_space * 2);
        var dead: usize = 0;
        for (0..entity.enemy_id_space) |i| {
            const gb_addr: u16 = @as(u16, xptr_gb[i * 2]) | (@as(u16, xptr_gb[i * 2 + 1]) << 8);
            const in_range = gb_addr >= hb_e.gb_addr and gb_addr < hb_e.gb_addr + hb_gb.len;
            const aligned = in_range and (gb_addr - hb_e.gb_addr) % entity.hitbox_bytes == 0;
            const rel: u16 = if (aligned) gb_addr - hb_e.gb_addr else blk2: {
                dead += 1;
                break :blk2 entity.dead_pointer;
            };
            xout[i * 2] = @truncate(rel);
            xout[i * 2 + 1] = @truncate(rel >> 8);
        }
        // Measured, not assumed: exactly one entry in the retail ROM is dead.
        // A second one appearing would mean the region's bounds moved.
        if (dead != 1) return Error.HitboxPointerOutOfRange;

        const dmg_e = offsets.find("enemy_damage") orelse return Error.UnresolvedSource;
        const dmg_gb = rom[dmg_e.romOffset()..dmg_e.romEnd()];
        if (dmg_gb.len != entity.enemy_id_space) return Error.DamageTableWrongLength;

        const en = try a.alloc(Blob, entity.which_count);
        en[@intFromEnum(entity.Which.data)] = .{ .name = "enemy_data", .bytes = try a.dupe(u8, data_gb) };
        en[@intFromEnum(entity.Which.pointers)] = .{ .name = "enemy_data_pointers", .bytes = out };
        en[@intFromEnum(entity.Which.headers)] = .{ .name = "enemy_headers", .bytes = try a.dupe(u8, hdr_gb) };
        en[@intFromEnum(entity.Which.header_pointers)] = .{ .name = "enemy_header_pointers", .bytes = hout };
        en[@intFromEnum(entity.Which.damage)] = .{ .name = "enemy_damage", .bytes = try a.dupe(u8, dmg_gb) };
        en[@intFromEnum(entity.Which.hitboxes)] = .{ .name = "enemy_hitboxes", .bytes = try a.dupe(u8, hb_gb) };
        en[@intFromEnum(entity.Which.hitbox_pointers)] = .{ .name = "enemy_hitbox_pointers", .bytes = xout };
        set.enemies = en;
    }

    set.aram = try aramBlobs(a, rom);
    set.title_art = try titleArtBlobs(a);
    set.debug = try debugBlobs(a, rom, walked);
    set.gfx_info = try gfx_info.decode(rom);

    return set;
}

/// `assets/title_super.png` as the three blobs `UploadTitleArt` reads.
fn titleArtBlobs(a: std.mem.Allocator) ![]Blob {
    const b = try title_super.blobs(a);
    const out = try a.alloc(Blob, 3);
    out[0] = .{ .name = "title_super_chr", .bytes = b.chr };
    out[1] = .{ .name = "title_super_pal", .bytes = b.pal };
    out[2] = .{ .name = "title_super_map", .bytes = b.map };
    return out;
}

/// The debug menu's METROIDS and FLAGS lists, from the ROM's spawn records,
/// and the WARP page's, from the door crawl (1.0 Step 5b).
fn debugBlobs(a: std.mem.Allocator, rom: []const u8, walked: []const warp.WalkedDoor) ![]Blob {
    const W = debug_tables.Which;
    const out = try a.alloc(Blob, @typeInfo(W).@"enum".fields.len);
    out[@intFromEnum(W.metroids)] = .{ .name = "debug_metroids", .bytes = try debug_tables.metroidsBlob(a, rom) };
    out[@intFromEnum(W.flags)] = .{ .name = "debug_flags", .bytes = try debug_tables.flagsBlob(a, rom) };
    const built = try warp.build(a, rom, walked);
    const wb = try debug_tables.warpBlobs(a, rom, built.entries);
    for (debug_tables.warp_lists, wb.lists) |w, l| out[@intFromEnum(w)] = .{ .name = @tagName(w), .bytes = l };
    out[@intFromEnum(W.warp_data)] = .{ .name = "warp_data", .bytes = wb.data };
    out[@intFromEnum(W.larvae)] = .{ .name = "debug_larvae", .bytes = try debug_tables.larvaeBlob(a, rom) };
    return out;
}

/// The assembled sound engine, committed as `engine.bin` is and embedded the
/// same way, so the shipped builder still needs nothing but itself and a ROM.
pub const audio_bin = @embedFile("audio_bin");

/// The ARAM image, cut into the blocks the cart uploads. Hosted mode without
/// the write trace: the trace is a bench instrument, and on a console it would
/// cost the engine a write per register write for a buffer nobody drains.
fn aramBlobs(a: std.mem.Allocator, rom: []const u8) ![]Blob {
    const img = try aram_image.build(a, rom, audio_bin, .hosted);
    const blocks = try aram_image.uploadBlocks(a, img);
    const out = try a.alloc(Blob, blocks.len);
    for (blocks, out) |b, *o| {
        const bytes = try a.alloc(u8, 2 + b.bytes.len);
        std.mem.writeInt(u16, bytes[0..2], b.aram, .little);
        @memcpy(bytes[2..], b.bytes);
        o.* = .{ .name = try std.fmt.allocPrint(a, "aram_{X:0>4}", .{b.aram}), .bytes = bytes };
    }
    return out;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "metatile conversion round-trips, and refuses a word it did not write" {
    const gpa = testing.allocator;
    const gb = [_]u8{ 0x00, 0x7F, 0x80, 0xFF, 0x12, 0x34, 0x56, 0x78 };
    const snes = try convertMetatiles(gpa, &gb);
    defer gpa.free(snes);
    try testing.expectEqual(@as(usize, 16), snes.len);
    // Little-endian words, char in the low ten bits, palette 0, and BG3's
    // priority bit ($20 in the high byte) since Step 24e.
    try testing.expectEqual(@as(u8, 0x7F), snes[2]);
    try testing.expectEqual(@as(u8, 0x20), snes[3]);
    try testing.expectEqual(@as(u8, 0xFF), snes[6]);
    try testing.expectEqual(@as(u8, 0x20), snes[7]);

    const back = try unconvertMetatiles(gpa, snes);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, &gb, back);

    // A word with a palette set is not one this converter produced.
    var tampered = try gpa.dupe(u8, snes);
    defer gpa.free(tampered);
    tampered[1] |= 0x04;
    try testing.expectError(Error.RaggedMetatileTable, unconvertMetatiles(gpa, tampered));
    try testing.expectError(Error.RaggedMetatileTable, convertMetatiles(gpa, gb[0..3]));
}

test "a warp keeps its operand and rebases only the bank" {
    const gpa = testing.allocator;
    _ = gpa;
    var out: [16]u8 = undefined;
    const empty: AssetIndex = .empty;
    const n = try convertOp(.{ .warp = .{ .bank = 0xE, .pos = 0x3C } }, empty, empty, .empty, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0x45), out[0]); // bank $E -> map index 5
    try testing.expectEqual(@as(u8, 0x3C), out[1]); // operand untouched

    // A bank outside $9-$F is a misparse, not a surprise.
    try testing.expectError(Error.WarpBankOutOfRange, convertOp(.{ .warp = .{ .bank = 0x8, .pos = 0 } }, empty, empty, .empty, &out));
}

test "operations carrying no address are passed through byte for byte" {
    var out: [16]u8 = undefined;
    var gb: [16]u8 = undefined;
    const empty: AssetIndex = .empty;
    const ops = [_]door.Op{
        .{ .tiletable = 3 },      .{ .collision = 1 }, .{ .solidity = 7 },
        .escape_queen,            .exit_queen,         .fadeout,
        .{ .song = 2 },           .{ .item = 9 },      .end,
        .{ .damage = .{ .acid = 5, .spike = 6 } },
        .{ .if_met_less = .{ .met_count = 0x46, .transition = 0x1234 } },
    };
    for (ops) |op| {
        const n = try convertOp(op, empty, empty, .empty, &out);
        const m = door.encodeOne(op, &gb);
        try testing.expectEqual(m, n);
        try testing.expectEqual(convertedSize(op), n);
        try testing.expectEqualSlices(u8, gb[0..m], out[0..n]);
    }
}

test "map cells round-trip back into the ROM's own screen pointers" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    for (map.first_bank..map.last_bank + 1) |b| {
        const bank: u8 = @intCast(b);
        var parsed = try map.parseBank(gpa, rom, bank);
        defer parsed.deinit(gpa);

        const cells = try convertBank(gpa, parsed);
        defer gpa.free(cells);
        const back = try unconvertBank(gpa, cells);
        defer gpa.free(back);

        const expect = try gpa.alloc(u8, map.cells * 2);
        defer gpa.free(expect);
        map.encodePointers(parsed, expect);
        try testing.expectEqualSlices(u8, expect, back);

        // The scroll byte and the transition word ride through untouched.
        for (parsed.cells, 0..) |c, i| {
            try testing.expectEqual(@as(u8, @bitCast(c.scroll)), cells[i * cell_bytes + 1]);
            const t: u16 = @as(u16, cells[i * cell_bytes + 2]) | (@as(u16, cells[i * cell_bytes + 3]) << 8);
            try testing.expectEqual(c.transition, t);
        }
    }
}

test "converting the whole ROM leaves nothing unresolved" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    var set = try run(gpa, rom);
    defer set.deinit();

    // Ten metatile tables, eight collision tables, seven map banks.
    try testing.expectEqual(@as(usize, 10), set.metatiles.len);
    try testing.expectEqual(@as(usize, 8), set.collision.len);
    try testing.expectEqual(@as(usize, 7), set.map_cells.len);
    try testing.expectEqual(@as(usize, 7), set.map_screens.len);
    try testing.expectEqual(@as(usize, tileset.solidity_bytes), set.solidity.bytes.len);

    // Every metatile table converts back to the ROM's own bytes.
    for (set.metatiles) |m| {
        const gb = tileset.slice(rom, m.name).?;
        const back = try unconvertMetatiles(gpa, m.bytes);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, gb, back);
    }

    // Every asset id a converted door op names must exist.
    var i: usize = 0;
    var ops: usize = 0;
    while (i < set.doors.bytes.len) {
        const opcode = set.doors.bytes[i];
        ops += 1;
        if (opcode == door.terminator) {
            i += 1;
            continue;
        }
        switch (opcode >> 4) {
            0x0 => {
                const asset = set.assetById(set.doors.bytes[i + 1]) orelse return error.TestUnexpectedResult;
                // And the Game Boy source carried after it names the same
                // entry the id was resolved from: the save buffer is written
                // from these three bytes, so they must be the original's.
                const gb_bank = set.doors.bytes[i + 8];
                const gb_addr = std.mem.readInt(u16, set.doors.bytes[i + 9 ..][0..2], .little);
                if (gb_bank != no_source_bank) {
                    const resolved = door.resolveSource(gb_bank, gb_addr) orelse return error.TestUnexpectedResult;
                    try testing.expectEqualStrings(asset.name, resolved.name);
                }
                i += copy_bytes;
            },
            // $B0-$BF is unallocated in the converted encoding: `LOAD` became
            // a `COPY` when `LOAD_spr` turned into two transfers.
            0xB => return error.TestUnexpectedResult,
            0x4 => {
                // Every warp names one of the seven map banks.
                try testing.expect((opcode & 0x0F) < map.bank_count);
                i += 2;
            },
            0x8 => {
                try testing.expect((opcode & 0x0F) < map.bank_count);
                i += 9;
            },
            0x6 => i += 3,
            0x9 => i += 4,
            else => i += 1,
        }
    }
    // Step 4's gate counts 1872 operations; the converted stream must hold
    // exactly as many, or an operand width is wrong and the walk above has
    // desynchronised without saying so.
    // 1872 Game Boy operations, plus one extra for each of the 234 that touch
    // the shared $8800-$8FFF window and so have to be made twice - 228
    // `LOAD_spr`, 3 `COPY_spr` and 3 `COPY_DATA gfx_commonItems` (Step 21).
    // Derived here rather than hardcoded, so the number moves with the ROM
    // instead of with this test.
    var gb_ops: usize = 0;
    var doubled: usize = 0;
    {
        var d = try door.decodeRegion(gpa, door.region(rom).?);
        defer d.deinit(gpa);
        gb_ops = d.ops.items.len;
        for (d.ops.items) |op| {
            const is_spr = switch (op) {
                .copy => |c| c.which == .spr or target.inSharedWindow(c.dest),
                .load => |l| l.which == .spr,
                else => false,
            };
            if (is_spr) doubled += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1872), gb_ops);
    try testing.expectEqual(@as(usize, 234), doubled);
    try testing.expectEqual(gb_ops + doubled, ops);

    // Every door pointer lands on an operation boundary in the new stream, or
    // on the end-of-stream offset the empty scripts share.
    var starts: std.AutoHashMapUnmanaged(u16, void) = .empty;
    defer starts.deinit(gpa);
    i = 0;
    while (i < set.doors.bytes.len) {
        try starts.put(gpa, @intCast(i), {});
        const opcode = set.doors.bytes[i];
        i += if (opcode == door.terminator) 1 else switch (opcode >> 4) {
            0x0 => copy_bytes,
            0xB => 2,
            0x4 => 2,
            0x8 => 9,
            0x6 => 3,
            0x9 => 4,
            else => 1,
        };
    }
    try starts.put(gpa, @intCast(set.doors.bytes.len), {});
    for (0..door.pointer_count) |p| {
        const off: u16 = @as(u16, set.door_pointers.bytes[p * 2]) |
            (@as(u16, set.door_pointers.bytes[p * 2 + 1]) << 8);
        try testing.expect(starts.contains(off));
    }
}

test "a transfer carries a source for the save buffer only where the Game Boy stores one" {
    // `door_copyData` (00:$2747) stores a source for `COPY_BG` and `COPY_SPR`
    // and not for `COPY_DATA`, and `door_loadGraphics` stores one for both
    // `LOAD`s. The engine's `.copy` arm stores what the converted copy carries,
    // so a `COPY_DATA` into the characters -- `gfx_commonItems` in three
    // scripts -- has to carry none, or the save after it names the item sheet
    // as the room's background and the load draws the room in it.
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try run(gpa, rom);
    defer set.deinit();

    const entry = offsets.find("door_data").?;
    var decoded = try door.decodeRegion(gpa, rom[entry.romOffset()..entry.romEnd()]);
    defer decoded.deinit(gpa);

    var at: usize = 0;
    var data_copies: usize = 0;
    for (decoded.ops.items) |op| {
        defer at += convertedSize(op);
        const stores = switch (op) {
            .copy => |c| c.which != .data,
            .load => true,
            else => continue,
        };
        const bank = set.doors.bytes[at + 8];
        if (stores) {
            try testing.expect(bank != no_source_bank);
        } else {
            data_copies += 1;
            try testing.expectEqual(no_source_bank, bank);
            if (convertedSize(op) == 2 * copy_bytes) try testing.expectEqual(no_source_bank, set.doors.bytes[at + copy_bytes + 8]);
        }
    }
    try testing.expectEqual(set.doors.bytes.len, at);
    try testing.expect(data_copies > 0);
}

test "every graphics source a save record can hold has a load" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try run(gpa, rom);
    defer set.deinit();

    const b = set.load_sources.bytes;
    const bg_n = b[0];
    const spr_n = b[1];
    try testing.expectEqual(load_entries_at + bg_n * copy_bytes + spr_n * 2 * copy_bytes, b.len);
    const has = struct {
        fn bg(bytes: []const u8, n: usize, bank: u8, addr: u16) bool {
            for (0..n) |k| {
                const e = bytes[load_entries_at + k * copy_bytes ..];
                if (e[8] == bank and std.mem.readInt(u16, e[9..11], .little) == addr) return true;
            }
            return false;
        }
        fn spr(bytes: []const u8, bg_count: usize, n: usize, addr: u16) bool {
            for (0..n) |k| {
                const e = bytes[load_entries_at + bg_count * copy_bytes + k * 2 * copy_bytes ..];
                if (@as(CopyClass, @enumFromInt(e[0])) != .obj) return false;
                if (std.mem.readInt(u16, e[9..11], .little) == addr) return true;
            }
            return false;
        }
    };

    // The new game's own, and James's first save's (`save.recorded_save`).
    const init = save.initial(rom).?;
    try testing.expect(has.bg(b, bg_n, init.bg_gfx_bank, init.bg_gfx_src));
    try testing.expect(has.spr(b, bg_n, spr_n, init.enemy_gfx_src));
    const rec = save.parseInitial(save.recorded_save[save.magic_len..]).?;
    try testing.expect(has.bg(b, bg_n, rec.bg_gfx_bank, rec.bg_gfx_src));
    try testing.expect(has.spr(b, bg_n, spr_n, rec.enemy_gfx_src));

    // And every source a door's transfer stores.
    const entry = offsets.find("door_data").?;
    var decoded = try door.decodeRegion(gpa, rom[entry.romOffset()..entry.romEnd()]);
    defer decoded.deinit(gpa);
    for (decoded.ops.items) |op| switch (op) {
        .load => |l| switch (l.which) {
            .bg => try testing.expect(has.bg(b, bg_n, l.src_bank, l.src_addr)),
            .spr => try testing.expect(has.spr(b, bg_n, spr_n, l.src_addr)),
        },
        .copy => |c| switch (c.which) {
            .bg => try testing.expect(has.bg(b, bg_n, c.src_bank, c.src_addr)),
            .spr => try testing.expect(has.spr(b, bg_n, spr_n, c.src_addr)),
            .data => {},
        },
        else => {},
    };

    // The item sheet a `COPY_DATA` moves is not a source, and must not have
    // become one.
    const items = offsets.find("gfx_commonItems").?;
    try testing.expect(!has.bg(b, bg_n, items.bank, items.gb_addr));

    // The two fixed transfers are the ROM's: the common items and the font,
    // read off `loadGame_loadGraphics`, and a perturbed routine is refused.
    const common = loadGraphicsCopy(rom, load_common_at).?;
    try testing.expectEqual(items.bank, common.bank);
    try testing.expectEqual(items.gb_addr, common.src);
    try testing.expectEqual(@as(u16, 0x8F00), common.dest);
    try testing.expectEqual(@intFromEnum(CopyClass.obj), b[load_prelude_at]);
    try testing.expectEqual(@intFromEnum(CopyClass.bg_twin), b[load_prelude_at + copy_bytes]);
    try testing.expectEqual(no_source_bank, b[load_prelude_at + copy_bytes + 8]);
    const font = loadGraphicsCopy(rom, load_font_at).?;
    const font_entry = offsets.find("gfx_itemFont").?;
    try testing.expectEqual(font_entry.bank, font.bank);
    try testing.expectEqual(font_entry.gb_addr, font.src);
    try testing.expectEqual(font_entry.size, font.len);
    try testing.expectEqual(@as(u16, 0x8C00), font.dest);
    try testing.expectEqual(font.src, std.mem.readInt(u16, b[load_font_entry_at + 9 ..][0..2], .little));
    try testing.expectEqual(no_source_bank, b[load_prelude_at + 8]);
    const bent = try gpa.dupe(u8, rom);
    defer gpa.free(bent);
    bent[load_font_at + 17] = 0xC3;
    try testing.expect(loadGraphicsCopy(bent, load_font_at) == null);
}

test "every converted character asset decodes back to the tiles it came from" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    var set = try run(gpa, rom);
    defer set.deinit();

    var over_read: usize = 0;
    for (set.assets) |asset| {
        // `gb_bytes` rather than the entry's size: three sheets are read past
        // their own end by a `LOAD` whose length the handler fixes, and the
        // converted asset carries those bytes. See `Usage.read_end`.
        const gb = rom[asset.rom_at..][0..asset.gb_bytes];
        if (offsets.find(asset.name)) |e| {
            if (asset.gb_bytes > e.size) over_read += 1;
        }
        switch (asset.kind) {
            .chr_bg => try testing.expectEqualSlices(u8, gb, asset.bytes),
            .chr_obj => {
                const back = try chr.from4bpp(gpa, asset.bytes);
                defer gpa.free(back);
                try testing.expectEqualSlices(u8, gb, back);
            },
            .tilemap => {
                // Through the same map the conversion used. The title's is a
                // rotation and the play field's is the identity, and inverting
                // one with the other's is a way of passing this test while
                // shipping a screen made of the wrong characters.
                const title = std.mem.eql(u8, asset.name, title_tilemap);
                const window = std.mem.eql(u8, asset.name, window_tilemap);
                try testing.expectEqual(gb.len * 2, asset.bytes.len);
                for (gb, 0..) |id, k| {
                    const w: u16 = @as(u16, asset.bytes[k * 2]) | (@as(u16, asset.bytes[k * 2 + 1]) << 8);
                    const back = if (title)
                        target.titleIdFromWord(@bitCast(w))
                    else if (window)
                        target.windowIdFromWord(@bitCast(w))
                    else
                        target.tileIdFromWord(@bitCast(w));
                    try testing.expectEqual(@as(?u8, id), back);
                }
            },
        }
    }
    // The three $530-byte lavaCaves sheets. Stated so the over-read stays a
    // known quantity rather than something that could quietly spread.
    try testing.expectEqual(@as(usize, 3), over_read);
}

test "the physics blobs are the arcs, with the terminator turned into a length" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    var set = try run(gpa, rom);
    defer set.deinit();

    try testing.expectEqual(physics.which_count, set.physics.len);
    for (set.physics, 0..) |b, i| {
        const which: physics.Which = @enumFromInt(i);
        // The blob's id is its index, which is what the engine's !PHYS_* names
        // are: a blob out of order would be a silently different table.
        try testing.expectEqualStrings(which.entry(), b.name);

        const e = offsets.find(which.entry()).?;
        const gb = rom[e.romOffset()..e.romEnd()];
        // Length is the whole of the conversion for an arc: a terminated one
        // loses its $80. The hitbox tables are geometry and lose nothing.
        const drops = which.isArc() and gb[gb.len - 1] == physics.terminator;
        try testing.expectEqual(gb.len - @intFromBool(drops), b.bytes.len);
        try testing.expectEqualSlices(u8, gb[0..b.bytes.len], b.bytes);
    }

    // The jump arcs terminate and the fall arc does not - which is the property
    // that makes the addresses evidence rather than three slices of bank 0.
    try testing.expectEqual(@as(usize, 0x17), set.physics[@intFromEnum(physics.Which.fall)].bytes.len);
    try testing.expectEqual(@as(usize, 0x4E), set.physics[@intFromEnum(physics.Which.jump)].bytes.len);
    try testing.expectEqual(@as(usize, 0x4E), set.physics[@intFromEnum(physics.Which.space_jump)].bytes.len);
}

test "every copy into the shared window writes the object characters too" {
    // $8800-$8FFF is the Game Boy's background *and* object characters, so one
    // transfer there serves both. `spr` was always split; `COPY_DATA
    // gfx_commonItems` to $8F00 was not, and the missile door, the drops and
    // the item orb drew from object characters nothing had written. The rule
    // is the destination's, not the opcode's.
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try run(gpa, rom);
    defer set.deinit();

    const entry = offsets.find("door_data").?;
    var decoded = try door.decodeRegion(gpa, rom[entry.romOffset()..entry.romEnd()]);
    defer decoded.deinit(gpa);

    const Has = struct {
        fn obj(b: []const u8, at: usize, n: usize, want: u16) bool {
            var k: usize = 0;
            while (k < n) : (k += copy_bytes) {
                const e = b[at + k ..][0..copy_bytes];
                if (@as(CopyClass, @enumFromInt(@as(u4, @truncate(e[0])))) == .obj and
                    std.mem.readInt(u16, e[4..6], .little) == want) return true;
            }
            return false;
        }
    };
    var at: usize = 0;
    var shared: usize = 0;
    for (decoded.ops.items) |op| {
        defer at += convertedSize(op);
        const dest: u16 = switch (op) {
            .copy => |c| c.dest,
            .load => |l| switch (l.which) {
                .bg => screens.load_bg_dest,
                .spr => screens.load_spr_dest,
            },
            else => continue,
        };
        if (!target.inSharedWindow(dest)) continue;
        shared += 1;
        try testing.expect(Has.obj(set.doors.bytes, at, convertedSize(op), try target.gbDestToObj(dest)));
    }
    try testing.expect(shared > 0);

    // And the load's own, which no door script carries: 00:$05FD.
    const common = loadGraphicsCopy(rom, load_common_at).?;
    try testing.expect(target.inSharedWindow(common.dest));
    try testing.expect(Has.obj(set.load_sources.bytes, load_prelude_at, load_font_entry_at - load_prelude_at, try target.gbDestToObj(common.dest)));
}

test "the window's map is BG2's, and the Queen's head is the only copy into it" {
    // 1.0 Step 6. Until it both Game Boy maps folded onto BG3's, which put the
    // head over the top of her room; and `window_tilemap` converts one asset
    // by name, which is only right while nothing else goes to $9C00 and it
    // goes nowhere else.
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);
    var set = try run(gpa, rom);
    defer set.deinit();

    const entry = offsets.find("door_data").?;
    var decoded = try door.decodeRegion(gpa, rom[entry.romOffset()..entry.romEnd()]);
    defer decoded.deinit(gpa);
    const head = offsets.find(window_tilemap).?;

    var at: usize = 0;
    var copies: usize = 0;
    for (decoded.ops.items) |op| {
        defer at += convertedSize(op);
        const c = switch (op) {
            .copy => |c| c,
            else => continue,
        };
        const from_head = c.src_bank == head.bank and c.src_addr >= head.gb_addr and c.src_addr < head.gb_addr + head.size;
        const to_window = c.dest >= target.gb_tilemap1_base and c.dest < target.gb_tilemap1_base + target.gb_tilemap_bytes;
        try testing.expectEqual(from_head, to_window);
        if (!to_window) continue;
        copies += 1;
        const e = set.doors.bytes[at..][0..copy_bytes];
        try testing.expectEqual(target.bg2_map_base + (c.dest - target.gb_tilemap1_base), std.mem.readInt(u16, e[4..6], .little));
    }
    try testing.expectEqual(@as(usize, 4), copies);
}

test "the Missile Tank and both refills draw only from the common item characters" {
    // Step 23. The Missile Tank was reported invisible on 2026-09-15 and was
    // visible again after Step 21, which changed nothing about items: it made
    // `gfx_commonItems` reach the object characters. This is the link. Every
    // part of the three sprites, read out of the ROM's own metasprite table,
    // names a character inside the 00:$05FD copy, which is the range the
    // `load` rung's code 174 holds to the ROM on the cart. So 174 guards them,
    // and a sprite that drew from anywhere else would fail here first.
    const items = @import("items.zig");
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    const common = loadGraphicsCopy(rom, load_common_at).?;
    const first: u16 = (common.dest - 0x8000) / 16;
    const end: u16 = first + common.len / 16;
    const ptrs = offsets.find("metasprite_enemies_pointers").?;
    const data = offsets.find("metasprite_enemies_data").?;

    const within = struct {
        fn f(r: []const u8, p: offsets.Entry, d: offsets.Entry, id: u8, lo: u16, hi: u16) !bool {
            const addr = std.mem.readInt(u16, r[p.romOffset() + @as(usize, id) * 2 ..][0..2], .little);
            var o = d.romOffset() + (addr - d.gb_addr);
            var parts: usize = 0;
            var inside = true;
            while (r[o] != entity.terminator) : (o += entity.part_bytes) {
                const tile = r[o + 2];
                if (tile < lo or tile >= hi) inside = false;
                parts += 1;
            }
            try testing.expect(parts > 0);
            return inside;
        }
    }.f;
    const item = struct {
        fn id(n: items.Collected) u8 {
            return items.sprite_item_base + 2 * (@intFromEnum(n) - 1);
        }
    };
    try testing.expectEqual(items.Collected.missile_tank, items.collectedFor(item.id(.missile_tank)).?);
    for ([_]u8{ item.id(.missile_tank), items.sprite_energy_refill, items.sprite_missile_refill }) |id| {
        try testing.expect(try within(rom, ptrs, data, id, first, end));
    }
    // And the check can tell: the Bomb draws from the sheet the `ITEM` opcode
    // loads, which is not this copy (Step 24's).
    try testing.expect(!try within(rom, ptrs, data, item.id(.bomb), first, end));
}
