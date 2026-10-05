//! The asset region layout: how much space the converted game reserves for each
//! class of data, and a validator that checks what the converter actually
//! produced against it.
//!
//! This is deliberately a *standalone manifest*, not something the injector
//! derives as it packs. The injector (Step 11) does not exist yet, and the
//! point of the split is that it never will be the authority on sizing: the
//! numbers below are a declaration, and `check` is the thing that can disagree
//! with the converter. An injector that computed its own regions could never
//! report an overflow, only produce a differently-shaped image.
//!
//! ## Why blobs are bank-packed rather than simply concatenated
//!
//! The 65816's DMA controller does not carry the A-bus bank across a transfer:
//! `$4302`/`$4303` are the low sixteen bits and `$4304` is the bank, and only
//! the low sixteen increment. A transfer that runs off the end of a bank wraps
//! to the bank's start instead of continuing into the next one. So any blob the
//! engine intends to DMA - every character sheet and every tilemap - must lie
//! entirely within one bank. The layout therefore pads rather than straddles,
//! and the padding is part of what a class costs. Counting only the raw bytes
//! would understate every class that contains a blob near a bank boundary.
//!
//! The tables that are read by the CPU rather than DMA'd (metatiles, collision,
//! the map, the door stream) are held to the same rule. They do not strictly
//! need it, but a table that straddles a bank forces long addressing on the
//! inner loop that reads it, and the padding it saves is smaller than the
//! reserve headroom below.
//!
//! Regions themselves are *not* bank-aligned. An earlier draft aligned each one
//! and it cost five banks of nothing: `solidity` is 32 bytes and `tilemap` is
//! 256, and rounding each of those up to 32 KiB pushed the cart from 512 KiB to
//! a megabyte. Regions are laid end to end instead, and a region's packing is
//! computed from where it actually starts - so a class's padding depends on its
//! neighbours' reserves, which is exactly the dependency a fixed manifest makes
//! safe to have. Only the engine image is bank-aligned, because code is.

const std = @import("std");
const convert = @import("snes_convert.zig");

/// LoROM: each bank contributes a 32 KiB window at `$8000`-`$FFFF`.
pub const Mapper = enum {
    lorom,
    hirom,

    pub fn bankSize(self: Mapper) usize {
        return switch (self) {
            .lorom => 0x8000,
            .hirom => 0x10000,
        };
    }
};

/// **Decided here, from the measured set.** See `docs/` and the plan's Step 8:
/// the whole converted asset set is well under a megabyte, so the choice is not
/// forced by capacity. LoROM wins on the thing that is actually scarce - the
/// engine's own addressing. LoROM's 32 KiB windows sit at `$8000` in every
/// bank, which leaves `$0000`-`$7FFF` of each data bank free for the WRAM
/// mirror and hardware registers without a second mapping mode, and it is what
/// every SNES assembler and emulator treats as the default. HiROM would buy
/// larger contiguous blobs, and nothing in the set needs one: the largest blob
/// the converter produces is reported by `check` and is a small fraction of a
/// LoROM bank.
pub const mapper: Mapper = .lorom;

pub const bank_size: usize = mapper.bankSize();

/// Reserved for the pre-assembled engine image (Step 11). Bank-aligned, and the
/// only region that is: it holds code, which is addressed by bank. The engine is not
/// written yet, so this is a reservation rather than a measurement, and it is
/// the one number in this file that is a guess. It is sized at four LoROM banks
/// because the Game Boy original's entire code footprint - all sixteen banks
/// minus the data regions `offsets.zig` names - is under 96 KiB, and the SNES
/// rewrite has no reason to need more than a comfortable margin over that.
pub const engine_reserved: usize = 4 * bank_size;

/// A class of converted data. One region each, in this order.
pub const Class = enum {
    chr_bg,
    chr_obj,
    tilemap,
    metatiles,
    collision,
    solidity,
    map_cells,
    map_screens,
    doors,
    door_pointers,
    /// Not converted data: the blob directory the injector builds so the engine
    /// can find an individual sheet, screen body, or table inside a region.
    /// Appended last so every earlier region keeps the offset Step 8 measured.
    directory,
    /// Samus's jump, fall and space-jump arcs. Appended after `directory` for
    /// the same reason `directory` was appended after `door_pointers`: a class
    /// added at the end moves nothing, and the directory describes every blob
    /// including the ones placed after it, so nothing requires it to be last.
    physics,
    /// Samus's metasprite set - the converted pointer table, the record data,
    /// and the four pose sprite-id tables. Appended for the same reason
    /// `physics` was.
    metasprites,
    /// The per-screen enemy spawn lists, the 11-byte headers, and both of
    /// their relocated pointer tables. Appended for the same reason the three
    /// classes above it were: a class added at the end moves no region that was
    /// already measured.
    enemies,
    /// The SPC700's ARAM image, as the blocks the boot uploads through the IPL
    /// (metroid2-audio Step 16a): the GB APU shim, the ported sound engine and
    /// bank 4's data, each blob a two-byte ARAM address and the bytes that go
    /// there. Appended last, so no region already measured moves -- and it is
    /// what took the cart past 512 KiB. See `reserved`.
    aram,
    /// "Super" on the title (metroid2-0b Step 24j): not the ROM's, but
    /// `assets/title_super.png` converted by `title_super.zig` -- its BG1
    /// characters, its palette, and its map patch, blob ids 0, 1 and 2.
    /// Appended last, for the reason every class since `directory` was.
    title_art,
    /// The debug menu's METROIDS and FLAGS lists (1.0 Step 4), built from the
    /// ROM by `debug_tables.zig`, blob ids 0 and 1, and the WARP page's four
    /// lists and their data (Step 5b), ids 2-6. Appended last, for the
    /// reason every class since `directory` was.
    debug,

    pub fn label(self: Class) []const u8 {
        return @tagName(self);
    }
};

pub const class_count = @typeInfo(Class).@"enum".fields.len;

/// Bytes reserved per class, in whole KiB. The headroom `check` reports is what
/// is left inside a region, not what a neighbour could borrow: regions do not
/// grow into each other, because the whole point of a fixed manifest is that
/// the injector's answer to "where does `map_screens` start" does not change
/// when a character sheet does.
///
/// The values are the measured size rounded up with deliberate slack. The two
/// character classes get roughly 60% headroom because Phase 0a converts the
/// Game Boy's art unchanged and later phases are expected to replace some of it
/// with wider 4bpp work; `map_screens` gets 40% because its size is fixed by
/// the ROM's 7 x 59 screen bodies and can only change if the game gains rooms.
/// The small tables get a flat 4 KiB, which is more slack than they can
/// plausibly need and still rounds to nothing against the cart.
///
/// `doors` is the one that has already moved. It was 8 KiB against a 3132-byte
/// stream until Step 9 found that a `spr` operation has to be emitted twice -
/// once per depth - which took the stream to 6906 and the region to 84% full.
/// Doubling it is the cheap answer; the stream is bounded by the ROM's 1872
/// operations and cannot grow again without the game growing.
pub const reserved: [class_count]usize = blk: {
    const K = 1024;
    var r: [class_count]usize = undefined;
    r[@intFromEnum(Class.chr_bg)] = 64 * K;
    // 64 KiB until 1.0 Step 22, 92% full at 60064, when the credits' object
    // sheets (`gfx_creditsSprTiles` and `gfx_creditsNumbers` at 4bpp, 8640
    // bytes) took it to 68704 (68256 packed). 72 KiB is 93%; the manifest is
    // 574 KiB of the 1 MiB cart.
    r[@intFromEnum(Class.chr_obj)] = 72 * K;
    r[@intFromEnum(Class.tilemap)] = 4 * K;
    r[@intFromEnum(Class.metatiles)] = 16 * K;
    r[@intFromEnum(Class.collision)] = 4 * K;
    r[@intFromEnum(Class.solidity)] = 4 * K;
    r[@intFromEnum(Class.map_cells)] = 16 * K;
    // 160 KiB until Step 12d, and it gave a bank and a half of its slack to
    // `metasprites` rather than let the cart double. 116224 packed against 144
    // KiB is still 27% headroom, and this is the one class whose size genuinely
    // cannot move without the game gaining rooms -- 7 map banks of 59 screen
    // bodies, counted, not estimated.
    r[@intFromEnum(Class.map_screens)] = 144 * K;
    r[@intFromEnum(Class.doors)] = 16 * K;
    r[@intFromEnum(Class.door_pointers)] = 4 * K;
    r[@intFromEnum(Class.directory)] = 4 * K;
    // 4 KiB until 1.0 Step 22, at 4056 bytes, when the credits' text (1251)
    // and their two small tables took it to 5347: 65% of 8 KiB.
    r[@intFromEnum(Class.physics)] = 8 * K;
    // 4 KiB until Step 12d, which shipped the enemy set: 5131 bytes of enemy
    // part lists and 510 of pointers on top of Samus's 2228 and 138 is 8071
    // before any bank padding, so 4 KiB was not close. Quadrupled rather than
    // doubled, because 8 KiB would have left 121 bytes and a region that full
    // is a region a bank boundary can overflow. Like `doors` it is bounded by
    // the ROM -- three sprite sets and a 255-entry id space -- and cannot grow
    // again without the game growing. The 12 KiB it needed came out of
    // `map_screens`' slack above, **so the cart stays 512 KiB**: this file's own
    // header records what it cost the last time a layout change pushed it to a
    // megabyte, and it was not worth it then either.
    r[@intFromEnum(Class.metasprites)] = 16 * K;
    // 4452 bytes of lists, 3584 of screen pointers, 572 of headers and 510 of
    // header pointers is 9118 - past 8 KiB before any bank padding, and 8 KiB
    // would have been the wrong answer even without the headers, because the
    // 8036 the first two come to leaves no room for the padding a bank boundary
    // between two blobs costs. The region is bounded by the ROM's 7 x 256
    // screens and its 255-entry id space and cannot grow without the game
    // growing, which is what makes a fixed 16 KiB safe rather than optimistic.
    r[@intFromEnum(Class.enemies)] = 16 * K;
    // metroid2-audio Step 16a. About 31 KB of blocks: 7.4 KB of shim, 7.9 KB
    // of engine, 9.7 KB of bank 4's data, 3.9 KB of samples and the 2 KB of
    // engine RAM the upload zeroes. **This is the class that doubled the cart,
    // on purpose.** The header's objection to a megabyte was padding -- five
    // banks of nothing -- and this is data; more maps and colour art will need
    // the room anyway (decided 2026-09-22). 48 KiB leaves the engine a third
    // again to grow into, and nothing else moves because the class is last.
    r[@intFromEnum(Class.aram)] = 48 * K;
    // Step 24j. 27 characters of 32 bytes, six of palette and a 60-byte map
    // patch: 930 bytes. 2 KiB leaves James room to redraw the art larger.
    r[@intFromEnum(Class.title_art)] = 2 * K;
    // 1.0 Step 4. 46 and 52 entries of 24 bytes and a count each: 2354
    // bytes. Bounded by the ROM's saved half, 128 numbers in each of seven
    // banks, and far from it. Step 5b adds the WARP page: 160 rows of 24 and
    // 160 of `warp_bytes`, 6405 bytes more, and a blob never crosses a bank.
    r[@intFromEnum(Class.debug)] = 12 * K;
    break :blk r;
};

/// Where a class's region begins, as an offset into the ROM image.
pub fn regionStart(class: Class) usize {
    var off: usize = engine_reserved;
    for (0..@intFromEnum(class)) |i| off += reserved[i];
    return off;
}

/// Total image size the manifest describes, before rounding to a cart size.
pub fn manifestEnd() usize {
    var off: usize = engine_reserved;
    for (reserved) |r| off += r;
    return off;
}

/// The cart size a mask ROM comes in: a power of two, at least 256 KiB.
pub fn romSize() usize {
    var size: usize = 256 * 1024;
    while (size < manifestEnd()) size *= 2;
    return size;
}

// ---- Measurement -----------------------------------------------------------

pub const ClassMeasure = struct {
    /// Sum of the blobs' own bytes.
    raw: usize = 0,
    /// Bytes the region actually consumes once blobs are bank-packed.
    packed_size: usize = 0,
    count: usize = 0,
    /// The largest single blob, which is what has to fit in one bank.
    largest: usize = 0,
    /// Name of the largest blob, for the report.
    largest_name: []const u8 = "",

    pub fn padding(self: ClassMeasure) usize {
        return self.packed_size - self.raw;
    }

    pub fn fits(self: ClassMeasure, reserve: usize) bool {
        return self.packed_size <= reserve and self.largest <= bank_size;
    }
};

pub const Measure = struct {
    classes: [class_count]ClassMeasure,
    by_basis: [3]usize,

    pub fn get(self: *const Measure, class: Class) ClassMeasure {
        return self.classes[@intFromEnum(class)];
    }

    pub fn fits(self: *const Measure) bool {
        for (self.classes, reserved) |c, r| {
            if (!c.fits(r)) return false;
        }
        return true;
    }

    pub fn totalRaw(self: *const Measure) usize {
        var n: usize = 0;
        for (self.classes) |c| n += c.raw;
        return n;
    }

    pub fn totalPacked(self: *const Measure) usize {
        var n: usize = 0;
        for (self.classes) |c| n += c.packed_size;
        return n;
    }
};

/// Lay blob sizes out from `start`, never straddling a bank, and write each
/// blob's absolute offset into `offsets` when it is given. Returns the bytes
/// consumed including the padding the no-straddle rule costs.
///
/// The injector calls this to decide *where* each blob goes and `measure` calls
/// it to decide *how much* a class costs. That is deliberate: two functions
/// implementing the same packing rule would be two things that can disagree,
/// and the disagreement would show up as a validator that passes while the
/// image it validated has a sheet in the wrong place.
pub fn place(start: usize, sizes: []const usize, offsets: ?[]usize) usize {
    var off: usize = start;
    for (sizes, 0..) |s, i| {
        if (s > bank_size) {
            // Cannot be placed at all; charge it in full so the total is still
            // an honest lower bound, and let `largest` be what reports it.
            if (offsets) |o| o[i] = off;
            off += s;
            continue;
        }
        if (off % bank_size + s > bank_size) off += bank_size - off % bank_size;
        if (offsets) |o| o[i] = off;
        off += s;
    }
    return off - start;
}

/// Classes whose blobs are one contiguous run rather than individually
/// bank-packed.
///
/// `metatiles` is the only one, and it is not a preference. The Game Boy's ten
/// metatile tables are a single region and a screen is allowed to index off the
/// end of its own table into the next - the three equal-sized `lavaCaves`
/// windows exist for exactly that, and `snes_render.tables` reproduces it.
/// Padding between the tables would put dead bytes exactly where the next
/// table's have to be, so the run is laid down whole. The rule that pays for it
/// is stricter, not looser: the entire run has to fit in one bank, because a
/// table that straddled one could not be read with a single bank register
/// either.
pub fn contiguous(class: Class) bool {
    return class == .metatiles;
}

/// Lay a class out under whichever of the two rules applies to it. Both the
/// injector and `measure` go through here, so neither can pack a class by a
/// rule the other does not know about.
pub fn placeClass(class: Class, start: usize, sizes: []const usize, offsets: ?[]usize) usize {
    if (!contiguous(class)) return place(start, sizes, offsets);

    var total: usize = 0;
    for (sizes) |s| total += s;
    var off = start;
    if (total <= bank_size and off % bank_size + total > bank_size) {
        off += bank_size - off % bank_size;
    }
    for (sizes, 0..) |s, i| {
        if (offsets) |o| o[i] = off;
        off += s;
    }
    return off - start;
}

fn packSizes(class: Class, start: usize, sizes: []const usize) usize {
    return placeClass(class, start, sizes, null);
}

fn measureBlobs(m: *ClassMeasure, class: Class, blobs: []const convert.Blob, buf: []usize) void {
    for (blobs, 0..) |b, i| {
        buf[i] = b.bytes.len;
        m.raw += b.bytes.len;
        if (b.bytes.len > m.largest) {
            m.largest = b.bytes.len;
            m.largest_name = b.name;
        }
    }
    m.count = blobs.len;
    if (contiguous(class)) {
        // What has to fit in one bank is the run, not the largest table in it,
        // so that is what `largest` reports - `fits` checks it against the bank
        // size and would otherwise pass a region no bank can hold.
        m.largest = m.raw;
        m.largest_name = class.label();
    }
    m.packed_size = packSizes(class, regionStart(class), buf[0..blobs.len]);
}

/// The number of blobs in any one class is bounded by the ROM's own tables -
/// 256 assets at most, 7 map banks, 10 metatile tables - so the packing buffer
/// can be a fixed array and `measure` needs no allocator. A converter that
/// somehow produced more would trip the assert rather than silently truncate.
pub const max_blobs = 512;

/// One directory entry per blob, including the directory's own. See
/// `snes_inject.zig` for the entry's shape; the size lives here because the
/// region it goes in is reserved here.
pub const directory_entry_bytes: usize = 8;

/// How many blobs the whole set contains, counting the directory itself. This
/// has to match what the injector writes exactly - a directory reserved for one
/// count and written with another would run into the next region - so both read
/// it from here.
pub fn blobCount(set: convert.Set) usize {
    return set.assets.len + set.metatiles.len + set.collision.len +
        1 + set.map_cells.len + set.map_screens.len + 2 + 1 +
        1 + set.physics.len + set.metasprites.len + set.enemies.len + set.aram.len + set.title_art.len + set.debug.len; // solidity, doors and load_sources, door_pointers, the directory
}

pub fn directoryBytes(set: convert.Set) usize {
    return blobCount(set) * directory_entry_bytes;
}

pub fn measure(set: convert.Set) Measure {
    var m: Measure = .{ .classes = @splat(.{}), .by_basis = set.by_basis };
    var buf: [max_blobs]usize = undefined;

    // The three asset classes share one list, split by kind.
    inline for (.{
        .{ Class.chr_bg, convert.AssetKind.chr_bg },
        .{ Class.chr_obj, convert.AssetKind.chr_obj },
        .{ Class.tilemap, convert.AssetKind.tilemap },
    }) |pair| {
        const class, const kind = pair;
        const c = &m.classes[@intFromEnum(class)];
        var n: usize = 0;
        for (set.assets) |a| {
            if (a.kind != kind) continue;
            std.debug.assert(n < max_blobs);
            buf[n] = a.bytes.len;
            n += 1;
            c.raw += a.bytes.len;
            if (a.bytes.len > c.largest) {
                c.largest = a.bytes.len;
                c.largest_name = a.name;
            }
        }
        c.count = n;
        c.packed_size = packSizes(class, regionStart(class), buf[0..n]);
    }

    std.debug.assert(set.metatiles.len <= max_blobs);
    std.debug.assert(set.map_screens.len <= max_blobs);

    measureBlobs(&m.classes[@intFromEnum(Class.metatiles)], .metatiles, set.metatiles, &buf);
    measureBlobs(&m.classes[@intFromEnum(Class.collision)], .collision, set.collision, &buf);
    measureBlobs(&m.classes[@intFromEnum(Class.solidity)], .solidity, &.{set.solidity}, &buf);
    measureBlobs(&m.classes[@intFromEnum(Class.map_cells)], .map_cells, set.map_cells, &buf);
    measureBlobs(&m.classes[@intFromEnum(Class.map_screens)], .map_screens, set.map_screens, &buf);
    measureBlobs(&m.classes[@intFromEnum(Class.doors)], .doors, &.{ set.doors, set.load_sources }, &buf);
    measureBlobs(&m.classes[@intFromEnum(Class.door_pointers)], .door_pointers, &.{set.door_pointers}, &buf);

    // The directory is the one class the converter does not produce: the
    // injector builds it. Its size is still a function of the set, so it is
    // measured here rather than discovered during injection - the point of the
    // manifest is that nothing sizes itself as it packs.
    const dir = &m.classes[@intFromEnum(Class.directory)];
    dir.raw = directoryBytes(set);
    dir.count = 1;
    dir.largest = dir.raw;
    dir.largest_name = "directory";
    dir.packed_size = packSizes(.directory, regionStart(.directory), &.{dir.raw});

    std.debug.assert(set.physics.len <= max_blobs);
    measureBlobs(&m.classes[@intFromEnum(Class.physics)], .physics, set.physics, &buf);

    std.debug.assert(set.metasprites.len <= max_blobs);
    measureBlobs(&m.classes[@intFromEnum(Class.metasprites)], .metasprites, set.metasprites, &buf);

    std.debug.assert(set.enemies.len <= max_blobs);
    measureBlobs(&m.classes[@intFromEnum(Class.enemies)], .enemies, set.enemies, &buf);

    std.debug.assert(set.aram.len <= max_blobs);
    measureBlobs(&m.classes[@intFromEnum(Class.aram)], .aram, set.aram, &buf);

    std.debug.assert(set.title_art.len <= max_blobs);
    measureBlobs(&m.classes[@intFromEnum(Class.title_art)], .title_art, set.title_art, &buf);

    std.debug.assert(set.debug.len <= max_blobs);
    measureBlobs(&m.classes[@intFromEnum(Class.debug)], .debug, set.debug, &buf);

    return m;
}

// ---- Report ----------------------------------------------------------------

pub fn print(m: Measure, out: *std.Io.Writer) !void {
    try out.print("mapper {s}, {d} KiB cart, engine reserve {d} KiB\n\n", .{
        @tagName(mapper), romSize() / 1024, engine_reserved / 1024,
    });
    try out.print("{s:<14} {s:>6} {s:>9} {s:>9} {s:>9} {s:>8}  {s}\n", .{
        "class", "blobs", "raw", "packed", "reserved", "headroom", "largest blob",
    });
    for (std.enums.values(Class)) |class| {
        const c = m.get(class);
        const r = reserved[@intFromEnum(class)];
        const head: isize = @as(isize, @intCast(r)) - @as(isize, @intCast(c.packed_size));
        try out.print("{s:<14} {d:>6} {d:>9} {d:>9} {d:>9} {d:>8}  {s} ({d})\n", .{
            class.label(), c.count, c.raw, c.packed_size, r, head,
            if (c.largest_name.len != 0) c.largest_name else "-",
            c.largest,
        });
        if (!c.fits(r)) {
            if (c.packed_size > r) {
                try out.print("  FAIL {s} overflows its region by {d} bytes\n", .{ class.label(), c.packed_size - r });
            }
            if (c.largest > bank_size) {
                try out.print("  FAIL {s}'s largest blob ({s}, {d} bytes) exceeds one {d}-byte bank\n", .{
                    class.label(), c.largest_name, c.largest, bank_size,
                });
            }
        }
    }
    try out.print("\ntotal {d} raw, {d} packed, {d} reserved; image ends at {d}, cart {d}\n", .{
        m.totalRaw(), m.totalPacked(), manifestEnd() - engine_reserved, manifestEnd(), romSize(),
    });
    try out.print("asset basis: {d} door_op, {d} shared_window, {d} entry_kind\n", .{
        m.by_basis[0], m.by_basis[1], m.by_basis[2],
    });
    try out.print("{s}\n", .{if (m.fits()) "ok    every class fits its region" else "FAIL  layout does not fit"});
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "regions are contiguous, non-overlapping, and inside the cart" {
    // Only the engine is bank-aligned; the data regions are laid end to end.
    try testing.expect(engine_reserved % bank_size == 0);
    var prev_end: usize = engine_reserved;
    for (std.enums.values(Class)) |class| {
        const start = regionStart(class);
        try testing.expectEqual(prev_end, start);
        try testing.expect(reserved[@intFromEnum(class)] % 1024 == 0);
        try testing.expect(reserved[@intFromEnum(class)] > 0);
        prev_end = start + reserved[@intFromEnum(class)];
    }
    try testing.expectEqual(manifestEnd(), prev_end);
    try testing.expect(romSize() >= manifestEnd());
    try testing.expect(romSize() % bank_size == 0);
    // A power of two, which is what a mask ROM comes in.
    try testing.expect(@popCount(romSize()) == 1);
}

test "packing never straddles a bank" {
    // Two blobs that fit a bank individually but not together: the second is
    // pushed to the next bank rather than split across the boundary.
    const c: Class = .chr_bg; // any class the contiguous rule does not claim
    const a = bank_size - 16;
    try testing.expectEqual(a, packSizes(c, 0, &.{a}));
    try testing.expectEqual(bank_size + 32, packSizes(c, 0, &.{ a, 32 }));
    // Exact fits waste nothing.
    try testing.expectEqual(bank_size, packSizes(c, 0, &.{ a, 16 }));
    try testing.expectEqual(2 * bank_size, packSizes(c, 0, &.{ bank_size, bank_size }));
    try testing.expectEqual(@as(usize, 0), packSizes(c, 0, &.{}));
    // The start offset is what makes a region's padding depend on where it
    // sits: the same blob costs nothing at a bank boundary and a pad just
    // before one.
    try testing.expectEqual(@as(usize, 64), packSizes(c, bank_size, &.{64}));
    try testing.expectEqual(@as(usize, 96), packSizes(c, bank_size - 32, &.{64}));
}

test "a contiguous class is laid down whole or moved whole" {
    // The tables sit back to back: no padding between them, whatever their
    // sizes. That is the property the Game Boy's off-the-end indexing needs.
    const m: Class = .metatiles;
    try testing.expect(contiguous(m));
    var off: [3]usize = undefined;
    try testing.expectEqual(@as(usize, 300), packSizes(m, 0, &.{ 100, 100, 100 }));
    _ = placeClass(m, 0, &.{ 100, 100, 100 }, &off);
    try testing.expectEqual([3]usize{ 0, 100, 200 }, off);

    // A run that would straddle a bank moves to the next one entire, so the
    // tables stay adjacent to each other rather than to the boundary.
    const near = bank_size - 64;
    try testing.expectEqual(@as(usize, 64 + 200), packSizes(m, near, &.{ 100, 100 }));
    _ = placeClass(m, near, &.{ 100, 100 }, off[0..2]);
    try testing.expectEqual([2]usize{ bank_size, bank_size + 100 }, off[0..2].*);
}

test "an oversized blob is reported rather than hidden" {
    var c: ClassMeasure = .{ .raw = bank_size + 1, .packed_size = bank_size + 1, .count = 1, .largest = bank_size + 1 };
    try testing.expect(!c.fits(8 * bank_size));
    c.largest = bank_size;
    try testing.expect(c.fits(8 * bank_size));
    try testing.expect(!c.fits(bank_size - 1));
}

test "the real converted set fits the layout" {
    const gpa = testing.allocator;
    const bytes = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(bytes);

    var set = try convert.run(gpa, bytes);
    defer set.deinit();

    const m = measure(set);
    for (std.enums.values(Class)) |class| {
        const c = m.get(class);
        const r = reserved[@intFromEnum(class)];
        if (!c.fits(r)) {
            std.debug.print("class {s}: packed {d} largest {d} reserved {d}\n", .{ class.label(), c.packed_size, c.largest, r });
        }
        try testing.expect(c.fits(r));
        // Every class has something in it. A class that measured zero would
        // mean the converter stopped producing it and the reserve would still
        // "fit" - the failure this catches is silence, not overflow.
        try testing.expect(c.count > 0);
        try testing.expect(c.raw > 0);
    }
    try testing.expect(m.fits());
    try testing.expect(m.totalPacked() >= m.totalRaw());
}
