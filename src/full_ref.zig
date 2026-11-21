//! The full scheme's palette slots, from its reference (colorization Step 3).
//!
//! The reference is EJRTQ's GBC colorization of Metroid II (romhacking.net
//! hack 4388, v1.3). It gives every graphics tile of banks 5-8 a palette
//! slot, and the full scheme takes those slots, not its colours. This reads them **statically** from the
//! patched ROM, built in memory and never written, and renders them as
//! `src/full_assign.zig`, which is committed. `docs/colorization.md` is the
//! model this relies on, with an address for each claim.
//!
//! What it reads, in the patched ROM:
//!  - **Source-tile slots.** A tile at bank N, address A has its slot at bank
//!    `$20+N`, address A. Every other byte of those banks is zero, and this
//!    checks it, so a byte the model does not explain is an error.
//!  - **The two per-sprite rules**, each read off its code with the shape
//!    checked: the OBP1 swap (`10:41A0`, and the same in the second pass at
//!    `10:41CA`) and the frozen-enemy palette (`01:7B87`).
//!  - **Tile-id edits.** Where EJRTQ shows tile ids the original does not
//!    (`hudBaseTilemap`, and the Queen-area screens and metatiles), the slot of
//!    the id it shows becomes the slot of the original id at that position.
//!    An original id that gets two slots is a conflict, settled by a hand
//!    choice in the generated file's hand-edited section.
//!  - **Look-alike slots.** Slots whose EJRTQ colours are identical, and slot
//!    pairs that pixel-identical tiles of one tileset are drawn in, where
//!    EJRTQ's colours agree on the shades those tiles use. Colours are compared
//!    in memory; none is rendered.
//!
//! Coverage over the recording is `full_ref_cover.zig`; the check against the
//! patched ROM in SameBoy is `full_ref_cgb.zig` (Step 5).

const std = @import("std");
const offsets = @import("offsets.zig");
const ips = @import("ips.zig");
const gb_trace = @import("gb_trace.zig");
const committed = @import("full_assign.zig");

pub const Error = error{
    /// The zip holds no file by the patch's name.
    NoPatchInZip,
    /// The patched ROM is not the shape `docs/colorization.md` describes.
    UnexpectedPatchedRom,
    /// A shadow-bank byte the model does not explain: a slot above 7, or a
    /// non-zero byte that is not the first byte of a graphics tile.
    UnexplainedAttribute,
    /// A rule's code is not the shape this reads it from.
    UnexpectedCode,
    /// A graphics region outside banks 5-8, or not a whole number of tiles.
    UnexpectedRegion,
    /// A tile-id edit whose shown id has no modelled source tile in VRAM.
    UnresidentTile,
    /// The rendered text carries a colour value from EJRTQ's block.
    ColourLeak,
    /// The rendered text is not valid Zig (a bad hand-edited section, or a
    /// rendering bug).
    UnparsableOutput,
};

pub const default_zip = "reference/Metroid_II_EJRTQ_Colorization_v1.3.zip";
pub const output_path = "src/full_assign.zig";

const bank_size = offsets.bank_size;
/// Where the slot of a tile in bank N lives: bank `$20+N`.
const shadow_bank_base: u8 = 0x20;
pub const patched_size: usize = 64 * bank_size;

/// The patch from EJRTQ's zip, hash-checked, applied to `rom`. Refuses any
/// other patch (`ips.Error.WrongPatch`), and checks the result is the 1 MiB
/// CGB-only MBC1 image the model describes.
pub fn patchedRom(allocator: std.mem.Allocator, rom: []const u8, zip: []const u8) ![]u8 {
    const patch = gb_trace.zipEntry(allocator, zip, ips.ejrtq_name) catch |e| switch (e) {
        error.NoSuchEntry => return Error.NoPatchInZip,
        else => return e,
    };
    defer allocator.free(patch);
    try ips.checkHash(patch, ips.ejrtq_sha1);
    const out = try ips.apply(allocator, rom, patch);
    errdefer allocator.free(out);
    // `$0143` CGB-only, `$0147` an MBC1 type ($01-$03; the patch leaves the
    // original's MBC1+RAM+BATTERY).
    if (out.len != patched_size or out[0x0143] != 0xC0 or out[0x0147] < 0x01 or out[0x0147] > 0x03)
        return Error.UnexpectedPatchedRom;
    return out;
}

fn flat(bank: u8, addr: u16) usize {
    return @as(usize, bank) * bank_size + (addr & 0x3FFF);
}

// ---- Colours, in memory only ----------------------------------------------

/// EJRTQ's colour block, `10:4000-407F`: eight palettes of four colours, each
/// colour two bytes of BG then two of OBJ (`10:4118` copies it to `$D180`).
/// Read to compare slots with each other. Nothing here is rendered.
pub const Colours = struct {
    bg: [8][4]u16,
    obj: [8][4]u16,

    pub fn layer(self: *const Colours, l: Layer) *const [8][4]u16 {
        return switch (l) {
            .bg => &self.bg,
            .obj => &self.obj,
        };
    }

    /// Every distinct value, for the leak check.
    pub fn values(self: Colours, buf: *[64]u16) []u16 {
        var n: usize = 0;
        for ([_][8][4]u16{ self.bg, self.obj }) |set| for (set) |pal| for (pal) |c| {
            if (std.mem.indexOfScalar(u16, buf[0..n], c) == null) {
                buf[n] = c;
                n += 1;
            }
        };
        return buf[0..n];
    }
};
pub const colour_block = flat(0x10, 0x4000);

pub fn colours(patched: []const u8) Colours {
    var out: Colours = undefined;
    for (0..8) |p| for (0..4) |c| {
        const at = colour_block + p * 16 + c * 4;
        out.bg[p][c] = std.mem.readInt(u16, patched[at..][0..2], .little);
        out.obj[p][c] = std.mem.readInt(u16, patched[at + 2 ..][0..2], .little);
    };
    return out;
}

// ---- Source-tile slots ----------------------------------------------------

pub const Layer = enum { bg, obj };

pub fn isGraphics(kind: offsets.Kind) bool {
    return switch (kind) {
        .graphics_enemy, .graphics_item, .graphics_samus, .graphics_tileset, .graphics_ui => true,
        else => false,
    };
}

/// One graphics region of `offsets.zig` and its tiles' slots.
pub const RegionSlots = struct {
    name: []const u8,
    /// Index into `offsets.entries`.
    entry: usize,
    slots: []u3,
};

/// The slot of the tile at bank `bank`, address `addr` of the original ROM.
pub fn sourceSlot(patched: []const u8, bank: u8, addr: u16) Error!u3 {
    const v = patched[flat(shadow_bank_base + bank, addr)];
    if (v > 7) return Error.UnexplainedAttribute;
    return @intCast(v);
}

/// A non-zero shadow-bank byte no graphics tile explains: the shadow bank
/// and address, and the byte.
pub const Stray = struct { bank: u8, addr: u16, value: u8 };

/// Strays that are understood, each with why it does not matter. Any other
/// stray fails the extraction.
pub const known_strays = [_]struct { stray: Stray, why: []const u8 }{
    .{
        .stray = .{ .bank = 0x27, .addr = 0x7BC0, .value = 1 },
        .why = "a slot for a tile in bank 7's free space (07:7B90 on, M2RoS bank_007.asm), which is zeros in both ROMs; no ROM holds a pointer to 07:7BC0",
    },
};

fn isKnownStray(s: Stray) bool {
    for (known_strays) |k| if (std.meta.eql(k.stray, s)) return true;
    return false;
}

/// Every graphics region's slots, in `offsets.entries` order. Appends each
/// shadow-bank byte the model does not explain, and `known_strays` does not
/// list, to `stray`.
pub fn regionSlots(allocator: std.mem.Allocator, patched: []const u8, stray: *std.ArrayList(Stray)) ![]RegionSlots {
    var list: std.ArrayList(RegionSlots) = .empty;
    // The shadow-bank bytes a tile explains, to find the ones nothing does.
    var explained = try std.DynamicBitSet.initEmpty(allocator, 4 * bank_size);
    defer explained.deinit();
    for (offsets.entries, 0..) |e, i| {
        if (!isGraphics(e.kind)) continue;
        if (e.bank < 5 or e.bank > 8 or e.size % 16 != 0) return Error.UnexpectedRegion;
        const slots = try allocator.alloc(u3, e.size / 16);
        for (slots, 0..) |*s, t| {
            const addr: u16 = @intCast(e.gb_addr + t * 16);
            s.* = try sourceSlot(patched, e.bank, addr);
            explained.set((e.bank - 5) * bank_size + (addr & 0x3FFF));
        }
        try list.append(allocator, .{ .name = e.name, .entry = i, .slots = slots });
    }
    const shadow = patched[flat(shadow_bank_base + 5, 0x4000)..][0 .. 4 * bank_size];
    for (shadow, 0..) |b, i| {
        if (b == 0 or explained.isSet(i)) continue;
        const s: Stray = .{
            .bank = @intCast(shadow_bank_base + 5 + i / bank_size),
            .addr = @intCast(0x4000 + i % bank_size),
            .value = b,
        };
        if (!isKnownStray(s)) try stray.append(allocator, s);
    }
    return list.toOwnedSlice(allocator);
}

// ---- The per-sprite rules -------------------------------------------------

/// An OBJ entry with the DMG OBP1 bit: slot `when` becomes `then`, any other
/// slot becomes `otherwise`.
pub const Obp1Swap = struct { when: u3, then: u3, otherwise: u3 };

/// `BIT 4,A / JR Z,+$0D / LD A,C / CP when / JR Z,+4 / LD C,otherwise / JR +4
/// / LD C,then`, with the three operands left open.
const swap_shape = [_]?u8{ 0xCB, 0x67, 0x28, 0x0D, 0x79, 0xFE, null, 0x28, 0x04, 0x0E, null, 0x18, 0x04, 0x0E, null };
/// Samus's pass and the pass after it (`docs/colorization.md`, Sprites).
const swap_sites = [_]u16{ 0x41A0, 0x41CA };

fn matchShape(bytes: []const u8, shape: []const ?u8) bool {
    if (bytes.len < shape.len) return false;
    for (shape, bytes[0..shape.len]) |want, have| {
        if (want) |w| if (w != have) return false;
    }
    return true;
}

fn smallOperand(v: u8) Error!u3 {
    if (v > 7) return Error.UnexpectedCode;
    return @intCast(v);
}

pub fn obp1Swap(patched: []const u8) Error!Obp1Swap {
    var found: ?Obp1Swap = null;
    for (swap_sites) |site| {
        const b = patched[flat(0x10, site)..];
        if (!matchShape(b, &swap_shape)) return Error.UnexpectedCode;
        const s: Obp1Swap = .{ .when = try smallOperand(b[6]), .otherwise = try smallOperand(b[10]), .then = try smallOperand(b[14]) };
        if (found) |f| if (!std.meta.eql(f, s)) return Error.UnexpectedCode;
        found = s;
    }
    return found.?;
}

/// `01:7B87`: `LD B,A / LD DE,5 / ADD HL,DE / LD A,(HL) / OR A / LD A,B / JR
/// Z,+2 / OR slot`. A frozen enemy's sprite attributes get `slot`.
const frozen_shape = [_]?u8{ 0x47, 0x11, 0x05, 0x00, 0x19, 0x7E, 0xB7, 0x78, 0x28, 0x02, 0xF6, null };
const frozen_site: u16 = 0x7B87;

pub fn frozenSlot(patched: []const u8) Error!u3 {
    const b = patched[flat(0x01, frozen_site)..];
    if (!matchShape(b, &frozen_shape)) return Error.UnexpectedCode;
    return smallOperand(b[11]);
}

// ---- What is in VRAM ------------------------------------------------------

/// A tile of a graphics region.
pub const SourceTile = struct { entry: u16, tile: u16 };

/// The Game Boy's 384 VRAM tiles (`$8000-$97FF`), each with the source tile
/// last copied there, or null where this does not model one.
pub const Vram = [384]?SourceTile;

fn place(vram: *Vram, region: []const u8, dest: u16, tiles: usize) Error!void {
    const e = offsets.find(region) orelse return Error.UnexpectedRegion;
    if (tiles * 16 > e.size) return Error.UnexpectedRegion;
    const entry: u16 = for (offsets.entries, 0..) |x, i| {
        if (std.mem.eql(u8, x.name, region)) break @intCast(i);
    } else unreachable;
    const first = (dest - 0x8000) / 16;
    for (0..tiles) |t| vram[first + t] = .{ .entry = entry, .tile = @intCast(t) };
}

/// VRAM in play, as `loadGame_loadGraphics` (00:$05FD) and a door's
/// background load leave it. Destinations are M2RoS's `SRC/ram/vram.asm`:
/// `vramDest_samus` $8000 (the power suit's $B00 bytes), `vramDest_itemFont`
/// $8C00 (the load's $200), `vramDest_commonItems` $8F00 (16 tiles),
/// `vramDest_bgTiles` $9000 (128 tiles). With `varia`, the Varia suit over
/// the first $7B0 bytes (`gfxInfo_variaSuit`, M2RoS `bank_000.asm`), so the
/// status bar's glyphs past tile $7A stay the power suit's. The enemy tiles
/// at `vramDest_enemies` ($8B00) change with the room and are not modelled,
/// nor are the small overlays a pose or a beam copies over Samus's.
pub fn playVram(varia: bool, tileset: []const u8) Error!Vram {
    var v: Vram = @splat(null);
    try place(&v, "gfx_samusPowerSuit", 0x8000, 0xB00 / 16);
    if (varia) try place(&v, "gfx_samusVariaSuit", 0x8000, 0x7B0 / 16);
    try place(&v, "gfx_itemFont", 0x8C00, 0x200 / 16);
    try place(&v, "gfx_commonItems", 0x8F00, 16);
    try place(&v, tileset, 0x9000, 128);
    return v;
}

/// The VRAM tile a background or window map byte shows, by LCDC's signed
/// addressing (`10:4175`): `$80-$FF` are tiles `$80-$FF`, `$00-$7F` are
/// tiles `$100-$17F`.
pub fn bgVramTile(id: u8) u16 {
    return if (id >= 0x80) id else 0x100 + @as(u16, id);
}

/// The slot `id` gets on the background, in `vram`.
pub fn bgSlot(slots: []const RegionSlots, vram: *const Vram, id: u8) ?u3 {
    const src = vram[bgVramTile(id)] orelse return null;
    for (slots) |r| if (r.entry == src.entry) return r.slots[src.tile];
    return null;
}

// ---- Tile-id edits --------------------------------------------------------

/// One map position: the id the original shows and the id EJRTQ shows.
pub const Edit = struct { orig: u8, shown: u8 };

/// An original id, and the slots EJRTQ's shown ids give it.
pub const Derived = struct {
    id: u8,
    /// Bit n set: some position shows slot n.
    slots: u8,

    pub fn conflict(self: Derived) bool {
        return @popCount(self.slots) > 1;
    }
    pub fn only(self: Derived) ?u3 {
        if (@popCount(self.slots) != 1) return null;
        return @intCast(@ctz(self.slots));
    }
};

/// The slot of each edited position's shown id, gathered per original id, in
/// every `vrams` state (without and with the Varia suit, since the status
/// bar's tiles are Samus's sheet's). Ascending by id.
pub fn derive(allocator: std.mem.Allocator, slots: []const RegionSlots, vrams: []const Vram, edits: []const Edit) ![]Derived {
    var masks: [256]u8 = @splat(0);
    var seen: [256]bool = @splat(false);
    for (edits) |e| {
        for (vrams) |*v| {
            const s = bgSlot(slots, v, e.shown) orelse return Error.UnresidentTile;
            masks[e.orig] |= @as(u8, 1) << s;
        }
        seen[e.orig] = true;
    }
    var out: std.ArrayList(Derived) = .empty;
    for (0..256) |id| if (seen[id]) try out.append(allocator, .{ .id = @intCast(id), .slots = masks[id] });
    return out.toOwnedSlice(allocator);
}

/// `hudBaseTilemap`'s twenty positions.
pub fn hudEdits(allocator: std.mem.Allocator, rom: []const u8, patched: []const u8) ![]Edit {
    const e = offsets.find("hudBaseTilemap").?;
    const out = try allocator.alloc(Edit, e.size);
    for (out, 0..) |*x, i| x.* = .{ .orig = rom[e.romOffset() + i], .shown = patched[e.romOffset() + i] };
    return out;
}

/// The Queen area's edits: every map-F screen whose data EJRTQ changed, read
/// through `metatiles_queen` as each ROM has it. A screen is 16x16 metatile
/// bytes; a metatile is four tile ids. Also returns which screens they were.
pub fn queenEdits(allocator: std.mem.Allocator, rom: []const u8, patched: []const u8, screens_out: *std.ArrayList(u8)) ![]Edit {
    const ptrs = offsets.find("mapF_screen_pointers").?;
    const meta = offsets.find("metatiles_queen").?;
    var out: std.ArrayList(Edit) = .empty;
    for (0..256) |s| {
        const p_at = ptrs.romOffset() + 2 * s;
        const orig_ptr = std.mem.readInt(u16, rom[p_at..][0..2], .little);
        const new_ptr = std.mem.readInt(u16, patched[p_at..][0..2], .little);
        const orig = rom[flat(ptrs.bank, orig_ptr)..][0..256];
        const shown = patched[flat(ptrs.bank, new_ptr)..][0..256];
        if (std.mem.eql(u8, orig, shown)) continue;
        try screens_out.append(allocator, @intCast(s));
        for (orig, shown) |mo, ms| {
            // Only the cells EJRTQ changed: a different metatile, or the same
            // one with different tiles.
            const mo_at = meta.romOffset() + @as(usize, mo) * 4;
            if (mo == ms and std.mem.eql(u8, rom[mo_at..][0..4], patched[mo_at..][0..4])) continue;
            for (0..4) |k| {
                try out.append(allocator, .{
                    .orig = rom[meta.romOffset() + @as(usize, mo) * 4 + k],
                    .shown = patched[meta.romOffset() + @as(usize, ms) * 4 + k],
                });
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- Look-alike slots -----------------------------------------------------

/// Slots `a` and `b` of `layer` must show the same colours for the shades in
/// `shades` (bit n: shade n).
pub const LookAlike = struct { layer: Layer, a: u3, b: u3, shades: u4 };

/// The shades a GB 2bpp tile uses, as a mask.
pub fn shadesUsed(tile: *const [16]u8) u4 {
    var m: u4 = 0;
    for (0..8) |row| {
        const lo = tile[row * 2];
        const hi = tile[row * 2 + 1];
        for (0..8) |bit| {
            const b: u3 = @intCast(bit);
            const shade: u2 = @intCast(((hi >> b) & 1) << 1 | ((lo >> b) & 1));
            m |= @as(u4, 1) << shade;
        }
    }
    return m;
}

fn agree(pals: *const [8][4]u16, a: u3, b: u3, shades: u4) bool {
    for (0..4) |s| {
        if ((shades >> @intCast(s)) & 1 == 0) continue;
        if (pals[a][s] != pals[b][s]) return false;
    }
    return true;
}

pub const LookAlikes = struct {
    /// Committed: the pairs that must look alike.
    keep: []LookAlike,
    /// Reported only: pixel-identical tiles in different slots that EJRTQ
    /// does draw differently.
    differ: []LookAlike,
    /// Every pixel-identical pair in different slots, for the report.
    pairs: []Pair,
};

pub const Pair = struct { region: []const u8, i: u16, j: u16, a: u3, b: u3, alike: bool };

/// Identical palettes, per layer; then, per background tileset, pairs of
/// pixel-identical tiles (original art) in different slots, with the shades
/// they use. Sorted, each (layer, a, b) once, masks merged.
pub fn lookAlikes(allocator: std.mem.Allocator, rom: []const u8, slots: []const RegionSlots, cols: Colours) !LookAlikes {
    // (layer, a, b) -> mask, with bit 4 meaning "differs".
    var masks: [2][8][8]u8 = @splat(@splat(@splat(0)));
    var pairs: std.ArrayList(Pair) = .empty;
    for ([_]Layer{ .bg, .obj }) |l| {
        const pals = cols.layer(l);
        for (0..8) |a| for (a + 1..8) |b| {
            if (std.mem.eql(u16, &pals[a], &pals[b])) masks[@intFromEnum(l)][a][b] |= 0xF;
        };
    }
    for (slots) |r| {
        const e = offsets.entries[r.entry];
        if (e.kind != .graphics_tileset) continue;
        const base = e.romOffset();
        for (0..r.slots.len) |i| for (i + 1..r.slots.len) |j| {
            const a = @min(r.slots[i], r.slots[j]);
            const b = @max(r.slots[i], r.slots[j]);
            if (a == b) continue;
            const ti = rom[base + i * 16 ..][0..16];
            if (!std.mem.eql(u8, ti, rom[base + j * 16 ..][0..16])) continue;
            const used = shadesUsed(ti);
            const alike = agree(&cols.bg, a, b, used);
            masks[0][a][b] |= used;
            if (!alike) masks[0][a][b] |= 0x10;
            try pairs.append(allocator, .{ .region = r.name, .i = @intCast(i), .j = @intCast(j), .a = r.slots[i], .b = r.slots[j], .alike = alike });
        };
    }
    var keep: std.ArrayList(LookAlike) = .empty;
    var differ: std.ArrayList(LookAlike) = .empty;
    for ([_]Layer{ .bg, .obj }) |l| for (0..8) |a| for (a + 1..8) |b| {
        const m = masks[@intFromEnum(l)][a][b];
        if (m == 0) continue;
        const x: LookAlike = .{ .layer = l, .a = @intCast(a), .b = @intCast(b), .shades = @truncate(m) };
        if (m & 0x10 != 0) try differ.append(allocator, x) else try keep.append(allocator, x);
    };
    return .{
        .keep = try keep.toOwnedSlice(allocator),
        .differ = try differ.toOwnedSlice(allocator),
        .pairs = try pairs.toOwnedSlice(allocator),
    };
}

// ---- The whole extraction -------------------------------------------------

pub const Extraction = struct {
    slots: []RegionSlots,
    obp1: Obp1Swap,
    frozen: u3,
    hud: []Derived,
    queen: []Derived,
    queen_screens: []u8,
    look: LookAlikes,
    colours: Colours,
    /// Must be empty for the model to hold.
    stray: []Stray,
    /// Per region, in `slots` order: the coverage characters, or empty.
    /// `extract` takes them from the committed file; the coverage pass
    /// replaces them.
    seen: []const []const u8 = &.{},
};

/// The committed file's `seen` string for region `name`, or empty.
pub fn committedSeen(name: []const u8) []const u8 {
    if (!@hasField(committed.Region, "seen")) return "";
    for (committed.regions) |r| if (std.mem.eql(u8, r.name, name)) return r.seen;
    return "";
}

pub fn extract(allocator: std.mem.Allocator, rom: []const u8, patched: []const u8) !Extraction {
    var stray: std.ArrayList(Stray) = .empty;
    const slots = try regionSlots(allocator, patched, &stray);
    const suits = [_]Vram{
        try playVram(false, "gfx_queenBG"),
        try playVram(true, "gfx_queenBG"),
    };
    var screens: std.ArrayList(u8) = .empty;
    const cols = colours(patched);
    const seen = try allocator.alloc([]const u8, slots.len);
    for (seen, slots) |*s, r| {
        s.* = committedSeen(r.name);
        // A region that changed size since coverage ran has none.
        if (s.len != r.slots.len) s.* = "";
    }
    return .{
        .seen = seen,
        .slots = slots,
        .obp1 = try obp1Swap(patched),
        .frozen = try frozenSlot(patched),
        .hud = try derive(allocator, slots, &suits, try hudEdits(allocator, rom, patched)),
        .queen = try derive(allocator, slots, &suits, try queenEdits(allocator, rom, patched, &screens)),
        .queen_screens = try screens.toOwnedSlice(allocator),
        .look = try lookAlikes(allocator, rom, slots, cols),
        .colours = cols,
        .stray = try stray.toOwnedSlice(allocator),
    };
}

// ---- Rendering ------------------------------------------------------------

/// The line that starts the hand-edited section. Everything from it on is
/// kept when the file is regenerated.
pub const hand_marker = "// ---- Hand-edited below this line. `zig build full-assign` keeps it as it is. ----";

pub const default_hand =
    hand_marker ++ "\n" ++
    \\
    \\/// Hand choices for the status bar's original ids (`hud`): one per
    \\/// conflict the oracle reports, or to replace a derived slot.
    \\pub const hud_choices = [_]Choice{};
    \\
    \\/// The same for the Queen area's ids (`queen`).
    \\pub const queen_choices = [_]Choice{};
    \\
    ;

/// The file's header and types: fixed text, so it is not a template.
const preamble =
    \\//! The `full` scheme's palette assignment: which palette slot each tile
    \\//! and sprite is drawn in (colorization F2).
    \\//!
    \\//! **Generated** by `zig build full-assign` from EJRTQ's GBC colorization of
    \\//! Metroid II (v1.3, on romhacking.net), except the hand-edited section
    \\//! at the end. `zig build full-assign -- check` diffs this file against a fresh
    \\//! extraction. `docs/colorization.md` describes the model and names the
    \\//! hack. (Not by its number here: the leak check would read it as a
    \\//! colour value.)
    \\//!
    \\//! It holds slot numbers and tile ids only: no colours and no ROM bytes.
    \\//! A slot is 0-7. The colours each slot gets are `colors.zig`'s.
    \\
    \\const std = @import("std");
    \\
    \\pub const Layer = enum { bg, obj };
    \\
    \\/// A graphics region of `offsets.zig`, and one slot digit per 16-byte tile,
    \\/// in ROM order. Sprites and the background share them. `seen` is what
    \\/// the recording showed of each tile (`zig build full-assign -- cover`): `.`
    \\/// never, so its slot is unobserved; `b` on the background or window
    \\/// only; `s` as a sprite only; `+` both. Empty: coverage not run.
    \\pub const Region = struct { name: []const u8, slots: []const u8, seen: []const u8 = "" };
    \\
    \\/// An OBJ entry with the DMG OBP1 bit: slot `when` becomes `then`, any
    \\/// other slot becomes `otherwise`.
    \\pub const Obp1Swap = struct { when: u3, then: u3, otherwise: u3 };
    \\
    \\/// Slots `a` and `b` of `layer` show the same colours for the shades in
    \\/// `shades` (bit n: shade n), so tiles that look alike stay alike.
    \\pub const LookAlike = struct { layer: Layer, a: u3, b: u3, shades: u4 };
    \\
    \\/// An original tile id at an edited position, and the slots (bit n: slot
    \\/// n) the ids EJRTQ shows there have. More than one bit is a conflict.
    \\pub const Derived = struct { id: u8, slots: u8 };
    \\
    \\/// A hand choice for an original tile id, with the reason.
    \\pub const Choice = struct { id: u8, slot: u3, why: []const u8 };
    \\
    \\/// The slot of tile `tile` of region `name`, or null if there is none.
    \\pub fn slot(name: []const u8, tile: usize) ?u3 {
    \\    for (regions) |r| {
    \\        if (!std.mem.eql(u8, r.name, name)) continue;
    \\        if (tile >= r.slots.len) return null;
    \\        return @intCast(r.slots[tile] - '0');
    \\    }
    \\    return null;
    \\}
    \\
    \\/// The slot for original id `id` at an edited position: the hand choice
    \\/// if there is one, else the derived slot if it is unique, else null.
    \\pub fn editSlot(derived: []const Derived, choices: []const Choice, id: u8) ?u3 {
    \\    for (choices) |c| if (c.id == id) return c.slot;
    \\    for (derived) |d| {
    \\        if (d.id != id) continue;
    \\        if (@popCount(d.slots) != 1) return null;
    \\        return @intCast(@ctz(d.slots));
    \\    }
    \\    return null;
    \\}
    \\
    \\pub fn hudSlot(id: u8) ?u3 {
    \\    return editSlot(&hud, &hud_choices, id);
    \\}
    \\
    \\pub fn queenSlot(id: u8) ?u3 {
    \\    return editSlot(&queen, &queen_choices, id);
    \\}
    \\
;

const digits_per_line = 64;

pub fn render(allocator: std.mem.Allocator, x: Extraction, hand: []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll(preamble);

    try w.writeAll("\npub const regions = [_]Region{\n");
    for (x.slots, 0..) |r, k| {
        try w.print("    .{{\n        .name = \"{s}\",\n        .slots = ", .{r.name});
        for (r.slots, 0..) |s, i| try wrapped(w, i, r.slots.len, '0' + @as(u8, s));
        const seen = if (k < x.seen.len) x.seen[k] else "";
        if (seen.len != 0) {
            try w.writeAll(",\n        .seen = ");
            for (seen, 0..) |c, i| try wrapped(w, i, seen.len, c);
        }
        try w.writeAll(",\n    },\n");
    }
    try w.writeAll("};\n");

    try w.print(
        \\
        \\/// `10:41A0` (and `10:41CA`).
        \\pub const obp1_swap: Obp1Swap = .{{ .when = {d}, .then = {d}, .otherwise = {d} }};
        \\
        \\/// A frozen enemy's slot (`01:7B87`). The OBP1 swap does not override it.
        \\pub const frozen_slot: u3 = {d};
        \\
        \\/// Identical palettes, and the slots pixel-identical tiles of one
        \\/// tileset are drawn in.
        \\pub const look_alikes = [_]LookAlike{{
        \\
    , .{ x.obp1.when, x.obp1.then, x.obp1.otherwise, x.frozen });
    for (x.look.keep) |l| try w.print("    .{{ .layer = .{t}, .a = {d}, .b = {d}, .shades = 0b{b:0>4} }},\n", .{ l.layer, l.a, l.b, l.shades });
    try w.writeAll("};\n");

    try w.writeAll("\n/// `hudBaseTilemap`'s original ids, from the ids EJRTQ shows there.\npub const hud = [_]Derived{\n");
    for (x.hud) |d| try w.print("    .{{ .id = 0x{X:0>2}, .slots = 0b{b:0>8} }},\n", .{ d.id, d.slots });
    try w.writeAll("};\n");
    try w.writeAll("\n/// The Queen area's original ids (map F screens");
    for (x.queen_screens) |s| try w.print(" ${X:0>2}", .{s});
    try w.writeAll("), from the ids EJRTQ shows there.\npub const queen = [_]Derived{\n");
    for (x.queen) |d| try w.print("    .{{ .id = 0x{X:0>2}, .slots = 0b{b:0>8} }},\n", .{ d.id, d.slots });
    try w.writeAll("};\n\n");

    try w.writeAll(hand);
    return zigFmt(allocator, buf.written());
}

/// Character `i` of a `len`-character string literal, broken into
/// `digits_per_line` pieces joined with `++`.
fn wrapped(w: *std.Io.Writer, i: usize, len: usize, c: u8) !void {
    if (i % digits_per_line == 0) {
        if (i != 0) try w.writeAll(" ++\n            ");
        try w.writeByte('"');
    }
    try w.writeByte(c);
    if (i % digits_per_line == digits_per_line - 1 or i == len - 1) try w.writeByte('"');
}

/// `text` as `zig fmt` leaves it, so the committed file is formatted however
/// the rendering above lays it out.
fn zigFmt(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const source = try allocator.dupeZ(u8, text);
    defer allocator.free(source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return Error.UnparsableOutput;
    return tree.renderAlloc(allocator);
}

/// The hand-edited section of `text`, marker included, or `default_hand`.
pub fn handSection(text: ?[]const u8) []const u8 {
    const t = text orelse return default_hand;
    const at = std.mem.indexOf(u8, t, hand_marker) orelse return default_hand;
    return t[at..];
}

pub const Leak = struct { value: u16, line: usize };

/// The first integer literal outside a string in `text` whose value is one
/// of `cols` and does not fit a byte, with its 1-based line. Byte-sized
/// values are slot numbers and tile ids, and can't be told from a colour; a
/// 16-bit one can. Comments count: a number in prose is still on disk. A
/// string ends at its line's end, so a stray quote in a comment can't hide
/// the lines after it.
pub fn colourLeak(text: []const u8, cols: []const u16) ?Leak {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            i += 1;
            while (i < text.len and text[i] != '"' and text[i] != '\n') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        const starts = std.ascii.isDigit(c) and (i == 0 or !(std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_'));
        if (!starts) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
        if (std.fmt.parseInt(u64, text[i..j], 0)) |v| {
            if (v > 0xFF and v <= 0xFFFF and std.mem.indexOfScalar(u16, cols, @intCast(v)) != null)
                return .{ .value = @intCast(v), .line = 1 + std.mem.count(u8, text[0..i], "\n") };
        } else |_| {}
        i = j;
    }
    return null;
}

/// Hand choices and the conflicts they settle.
pub const Unsettled = struct { table: []const u8, id: u8 };

/// Conflicts with no hand choice, and choices for an id with no derived entry.
pub fn unsettled(allocator: std.mem.Allocator, x: Extraction) !struct { open: []Unsettled, stale: []Unsettled } {
    var open: std.ArrayList(Unsettled) = .empty;
    var stale: std.ArrayList(Unsettled) = .empty;
    const tables = [_]struct { name: []const u8, derived: []const Derived, choices: []const committed.Choice }{
        .{ .name = "hud", .derived = x.hud, .choices = &committed.hud_choices },
        .{ .name = "queen", .derived = x.queen, .choices = &committed.queen_choices },
    };
    for (tables) |t| {
        for (t.derived) |d| {
            if (!d.conflict()) continue;
            const chosen = for (t.choices) |c| {
                if (c.id == d.id) break true;
            } else false;
            if (!chosen) try open.append(allocator, .{ .table = t.name, .id = d.id });
        }
        for (t.choices) |c| {
            const known = for (t.derived) |d| {
                if (d.id == c.id) break true;
            } else false;
            if (!known) try stale.append(allocator, .{ .table = t.name, .id = c.id });
        }
    }
    return .{ .open = try open.toOwnedSlice(allocator), .stale = try stale.toOwnedSlice(allocator) };
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the leak check finds a 16-bit colour literal, and skips strings and byte values" {
    const cols = [_]u16{ 0x0000, 0x00A9, 0x1DB1 };
    try testing.expectEqual(@as(?Leak, .{ .value = 0x1DB1, .line = 1 }), colourLeak("const x = 0x1DB1;", &cols));
    try testing.expectEqual(@as(?Leak, .{ .value = 0x1DB1, .line = 2 }), colourLeak("ok\n// prose 7601,", &cols));
    try testing.expectEqual(@as(?Leak, null), colourLeak(".id = 0xA9, .slots = 0b00000001", &cols));
    try testing.expectEqual(@as(?Leak, null), colourLeak(".slots = \"7601\" ++ \"0x1DB1\"", &cols));
    try testing.expectEqual(@as(?Leak, null), colourLeak("gfx_x7601 v0x1DB1", &cols));
    // A quote in a comment doesn't hide the next line.
    try testing.expectEqual(@as(?Leak, .{ .value = 0x1DB1, .line = 2 }), colourLeak("// a \" quote\nx = 0x1DB1", &cols));
}

test "signed addressing puts $80-$FF below $00-$7F" {
    try testing.expectEqual(@as(u16, 0x80), bgVramTile(0x80));
    try testing.expectEqual(@as(u16, 0xFF), bgVramTile(0xFF));
    try testing.expectEqual(@as(u16, 0x100), bgVramTile(0x00));
    try testing.expectEqual(@as(u16, 0x17F), bgVramTile(0x7F));
}

test "the rule shapes read their operands, and a perturbed shape is refused" {
    var mem: [patched_size]u8 = undefined;
    @memset(&mem, 0);
    const swap = [_]u8{ 0xCB, 0x67, 0x28, 0x0D, 0x79, 0xFE, 3, 0x28, 0x04, 0x0E, 3, 0x18, 0x04, 0x0E, 1 };
    for (swap_sites) |s| @memcpy(mem[flat(0x10, s)..][0..swap.len], &swap);
    try testing.expectEqual(Obp1Swap{ .when = 3, .then = 1, .otherwise = 3 }, try obp1Swap(&mem));
    // The two passes disagree.
    mem[flat(0x10, swap_sites[1]) + 14] = 2;
    try testing.expectError(Error.UnexpectedCode, obp1Swap(&mem));

    const frozen = [_]u8{ 0x47, 0x11, 0x05, 0x00, 0x19, 0x7E, 0xB7, 0x78, 0x28, 0x02, 0xF6, 3 };
    @memcpy(mem[flat(0x01, frozen_site)..][0..frozen.len], &frozen);
    try testing.expectEqual(@as(u3, 3), try frozenSlot(&mem));
    mem[flat(0x01, frozen_site) + 10] = 0xF7;
    try testing.expectError(Error.UnexpectedCode, frozenSlot(&mem));
}

test "shades used, from 2bpp planes" {
    var t: [16]u8 = @splat(0);
    try testing.expectEqual(@as(u4, 0b0001), shadesUsed(&t));
    t[0] = 0x80; // shade 1 at one pixel
    t[3] = 0x01; // shade 2 at one pixel
    try testing.expectEqual(@as(u4, 0b0111), shadesUsed(&t));
}

test "derive gathers slots per original id and flags a conflict" {
    // Two regions: the suit at $8000 and a tileset at $9000, as `playVram`
    // places them, with synthetic slots.
    const suit_entry: u16 = 0;
    const set_entry: u16 = 1;
    var suit_slots: [176]u3 = @splat(0);
    suit_slots[0x9D] = 2;
    suit_slots[0xA9] = 5;
    suit_slots[0x9E] = 2;
    var set_slots: [128]u3 = @splat(0);
    const slots = [_]RegionSlots{
        .{ .name = "suit", .entry = suit_entry, .slots = &suit_slots },
        .{ .name = "set", .entry = set_entry, .slots = &set_slots },
    };
    var v: Vram = @splat(null);
    for (0..176) |t| v[t] = .{ .entry = suit_entry, .tile = @intCast(t) };
    for (0..128) |t| v[0x100 + t] = .{ .entry = set_entry, .tile = @intCast(t) };

    const edits = [_]Edit{
        .{ .orig = 0xAF, .shown = 0x9D },
        .{ .orig = 0xAF, .shown = 0xA9 },
        .{ .orig = 0x9E, .shown = 0x9E },
    };
    const d = try derive(testing.allocator, &slots, &.{v}, &edits);
    defer testing.allocator.free(d);
    try testing.expectEqual(@as(usize, 2), d.len);
    try testing.expectEqual(Derived{ .id = 0x9E, .slots = 0b100 }, d[0]);
    try testing.expectEqual(@as(?u3, 2), d[0].only());
    try testing.expect(d[1].conflict());
    try testing.expectEqual(@as(u8, 0b100100), d[1].slots);

    // An id with nothing modelled under it is an error, not slot 0.
    try testing.expectError(Error.UnresidentTile, derive(testing.allocator, &slots, &.{v}, &.{.{ .orig = 1, .shown = 0xC0 }}));
}

test "the hand section is kept, and a file without one gets the default" {
    try testing.expectEqualStrings(default_hand, handSection(null));
    try testing.expectEqualStrings(default_hand, handSection("no marker here"));
    const text = "generated\n" ++ hand_marker ++ "\nmine\n";
    try testing.expectEqualStrings(hand_marker ++ "\nmine\n", handSection(text));
}

test "the committed file's helpers read slots and settle edits" {
    try testing.expectEqual(@as(?u3, 5), committed.editSlot(
        &.{.{ .id = 0xAF, .slots = 0b100100 }},
        &.{.{ .id = 0xAF, .slot = 5, .why = "test" }},
        0xAF,
    ));
    try testing.expectEqual(@as(?u3, null), committed.editSlot(&.{.{ .id = 0xAF, .slots = 0b100100 }}, &.{}, 0xAF));
    try testing.expectEqual(@as(?u3, 2), committed.editSlot(&.{.{ .id = 0x9E, .slots = 0b100 }}, &.{}, 0x9E));
}

test "the rendered file round-trips slot digits and keeps the hand section" {
    var s: [3]u3 = .{ 0, 7, 3 };
    const x: Extraction = .{
        .slots = @constCast(&[_]RegionSlots{.{ .name = "gfx_x", .entry = 0, .slots = &s }}),
        .obp1 = .{ .when = 3, .then = 1, .otherwise = 3 },
        .frozen = 3,
        .hud = &.{},
        .queen = &.{},
        .queen_screens = &.{},
        .look = .{ .keep = &.{}, .differ = &.{}, .pairs = &.{} },
        .colours = undefined,
        .stray = &.{},
        .seen = &.{"b.+"},
    };
    const text = try render(testing.allocator, x, default_hand);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".name = \"gfx_x\",\n        .slots = \"073\",\n        .seen = \"b.+\",") != null);
    try testing.expect(std.mem.endsWith(u8, text, default_hand));
    try testing.expectEqualStrings(default_hand, handSection(text));
}
