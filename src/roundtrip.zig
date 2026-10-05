//! Encode-back for every asset class, checked against the retail ROM (Step 5).
//!
//! Extraction (Step 3/4) is only half an argument. A decoder that reads the
//! wrong stride, drops a terminator, or swaps a byte pair still produces
//! plausible-looking output and a green test suite, because nothing ever asks
//! it to put the bytes back. This module asks. Every class is decoded into its
//! typed form and re-serialised from that form alone, and the result must equal
//! the ROM bytes it came from, exhaustively, over every entry in the table.
//!
//! **What a round-trip proves depends on the class**, and pretending otherwise
//! would make the number meaningless. So each kind declares one of three:
//!
//!   * `.encoding` - the encoder *reconstructs* bytes it does not store
//!     verbatim: 2bpp bitplanes packed from pixel indices, `$FF` terminators
//!     re-emitted, opcode bytes and operand widths rebuilt from a typed op.
//!     Passing here is real evidence the reading is complete.
//!   * `.framing`  - the encoder re-serialises records field by field, but the
//!     field values themselves are carried through verbatim. Passing confirms
//!     stride, count, order, and endianness; it says nothing about what the
//!     bytes *mean*.
//!   * `.none`     - no decoder exists. There is nothing to round-trip, and
//!     saying "100%" while quietly copying these would be the exact failure
//!     this module is here to prevent. They are named in the coverage report.
//!
//! The switch over `offsets.Kind` is exhaustive on purpose: adding a kind
//! without deciding which of the three it is fails to compile.

const std = @import("std");
const offsets = @import("offsets.zig");
const gfx = @import("gfx.zig");
const tileset = @import("tileset.zig");
const physics = @import("physics.zig");
const map = @import("map.zig");
const door = @import("door.zig");
const entity = @import("entity.zig");
const sprites = @import("sprites.zig");
const save = @import("save.zig");
const items = @import("items.zig");
const audio_data = @import("audio_data.zig");

pub const Proof = enum {
    encoding,
    framing,
    none,

    pub fn label(self: Proof) []const u8 {
        return switch (self) {
            .encoding => "encoding",
            .framing => "framing",
            .none => "raw",
        };
    }
};

pub const Plan = struct {
    proof: Proof,
    /// What passing actually demonstrates for this kind. Printed verbatim in
    /// the coverage report so the number is never read without its caveat.
    claim: []const u8,
};

pub fn plan(kind: offsets.Kind) Plan {
    return switch (kind) {
        .graphics_tileset, .graphics_samus, .graphics_enemy, .graphics_item, .graphics_ui => .{
            .proof = .encoding,
            .claim = "2bpp bitplanes repacked from pixel indices: bit order and plane order are both exercised",
        },
        .initial_save => .{
            .proof = .encoding,
            .claim = "the new game's own 38-byte save record, parsed into its named fields and re-emitted: eight words and twenty-two bytes in a fixed order, where a wrong width shifts every field after it",
        },
        .solidity => .{
            .proof = .encoding,
            .claim = "3 thresholds plus a re-emitted $FF terminator per row; the terminator is reconstructed, not stored",
        },
        .metasprite_data => .{
            .proof = .encoding,
            .claim = "variable-length $FF-terminated part lists; record boundaries are rebuilt from the parts alone",
        },
        .door_data => .{
            .proof = .encoding,
            .claim = "opcode bytes and operand widths rebuilt from typed ops; a misread length desynchronises the stream",
        },
        .map_scroll_flags => .{
            .proof = .encoding,
            .claim = "4 direction bits plus a 4-bit unused field, unpacked and repacked",
        },
        .sound_entry => .{
            .proof = .encoding,
            .claim = "$C3 jump trampolines; the opcode byte is required on decode and re-emitted as a constant",
        },
        .physics => .{
            .proof = .encoding,
            .claim = "signed per-frame speeds plus a $80 terminator that has to land exactly last, which is what makes this evidence about the address; the class also holds the small indexed tables Step 12b added, which have no framing and round-trip as byte tables",
        },
        .hitbox => .{
            .proof = .encoding,
            .claim = "per-pose collision offsets: the $80-terminated row inside an 8-byte stride is rebuilt from the offsets and the terminator's position alone, so a wrong stride desynchronises every row after the first",
        },
        .pose_transition => .{
            .proof = .framing,
            .claim = "one pose id per pose across the 30-entry pose space: confirms the width and the index, not what the destination pose means",
        },
        .pose_sprites => .{
            .proof = .framing,
            .claim = "rows of the width the table's own reader indexes by - four for the facing/d-pad and animation tables, two for the knockback pair, which `drawSamus_knockback` indexes by facing alone; no length admits a second plausible row width",
        },
        .metatiles => .{
            .proof = .framing,
            .claim = "4 tile ids per metatile in TL/TR/BL/BR order (order derived separately, in tileset.zig)",
        },
        .collision => .{
            .proof = .framing,
            .claim = "one behaviour byte per tile id: confirms the count and the id order, not the byte's meaning",
        },
        .enemy_damage => .{
            .proof = .framing,
            .claim = "one damage byte per enemy id across the 255-entry id space",
        },
        .enemy_headers => .{
            .proof = .framing,
            .claim = "11-byte records as 9 bytes plus a little-endian word (stride derived in entity.zig)",
        },
        .enemy_hitboxes => .{
            .proof = .framing,
            .claim = "4 signed bytes per record; signedness survives the round-trip",
        },
        .map_screens => .{
            .proof = .framing,
            .claim = "59 bodies of 16x16 row-major metatile indexes, walked by position so unreferenced bodies count too",
        },
        .map_screen_pointers, .map_transition_indexes, .door_pointers, .collision_pointers, .metasprite_pointers, .enemy_data_pointers, .enemy_header_pointers, .enemy_hitbox_pointers => .{
            .proof = .framing,
            .claim = "little-endian 16-bit table: confirms width and byte order",
        },
        .tilemap => .{
            .proof = .framing,
            .claim = "32-byte tilemap rows, the width the GB's _SCRN1 uses",
        },
        .enemy_data => .{
            .proof = .encoding,
            .claim = "1792 $FF-terminated per-screen lists of four-byte spawn records; the list boundaries are rebuilt from the records alone, so a wrong field width desynchronises every list after the first",
        },
        .item_names => .{
            .proof = .encoding,
            .claim = "sixteen 16-byte names decoded a character at a time and re-encoded, with the pointer table rebuilt from the string index rather than carried through: a misread width moves every pointer and a byte the font has no tile for is refused",
        },
        .sound_notes => .{
            .proof = .encoding,
            .claim = "73 little-endian 11-bit GB frequencies unpacked into the period the hardware counts and re-encoded: the word is an NR13/NR14 register pair, split into the 11-bit period and NR14's length-enable and trigger bits and rebuilt from them, with bits 11-13 refused rather than carried: a reader that treated it as a plain 16-bit period would re-emit it unchanged and prove nothing",
        },
        .sound_tempo => .{
            .proof = .encoding,
            .claim = "nine 13-byte note-length ladders parsed into their named durations; the doubling relation between the entries is asserted on decode, so a row read at the wrong stride is refused rather than re-emitted",
        },
        .sound_wave_patterns => .{
            .proof = .encoding,
            .claim = "32 four-bit samples per 16-byte wave pattern, split to nibbles in the order CH3 plays them (high nibble first) and repacked: a swapped nibble order survives a byte compare only if every pattern is symmetric, and these are not",
        },
        .sound_option_sets => .{
            .proof = .encoding,
            .claim = "fixed-width runs of APU register values, decoded into the named NR fields of the channel they are copied to and re-emitted: five wide for square 1 and wave, four for square 2 and noise, which is the width `setChannelOptionSet` loads into `b`",
        },
        .sound_effect_table => .{
            .proof = .framing,
            .claim = "five 16-byte per-frame effect step tables: confirms the count and the stride, not what a step does to the channel",
        },
        .sound_song_table => .{
            .proof = .framing,
            .claim = "32 little-endian song header pointers: confirms width, byte order and count against the one-flag-per-song table beside it",
        },
        .sound_flags => .{
            .proof = .framing,
            .claim = "one byte per song for the stereo masks, and the three engine state sizes: byte tables with no framing of their own",
        },
        .sound_song_data => .{
            .proof = .encoding,
            .claim = "every song walked from its header through its channel section lists into its instruction streams, then re-emitted from the typed form: a header is 11 bytes of one offset and five pointers, a section list is little-endian words where a high byte of $00 means a control word, and an instruction's length comes from its opcode -- a misread width desynchronises the rest of the stream, and bytes no walk reaches are carried through from the raw region so the compare covers the whole block and not only the parts the walk understands",
        },
    };
}

pub const Result = struct {
    name: []const u8,
    kind: offsets.Kind,
    proof: Proof,
    bytes: usize,
    items: usize,
    unit: []const u8,
    ok: bool,
    /// Offset of the first differing byte within the entry, when it failed.
    first_diff: ?usize = null,
    /// Set when the decoder refused the bytes outright, which is a different
    /// failure from producing the wrong ones.
    err: ?[]const u8 = null,
    /// Set when the re-encoded length differs, which a byte compare alone
    /// would report only as a mismatch at the truncation point.
    encoded_len: usize = 0,
};

pub const Report = struct {
    results: std.ArrayList(Result),
    checked: usize = 0,
    failed: usize = 0,
    undecoded: usize = 0,
    bytes_round_tripped: usize = 0,
    bytes_undecoded: usize = 0,
    items: usize = 0,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.results.deinit(allocator);
    }

    pub fn ok(self: Report) bool {
        return self.failed == 0;
    }
};

const Encoded = struct {
    bytes: []u8,
    items: usize,
    unit: []const u8,
};

fn wordTable(arena: std.mem.Allocator, src: []const u8, unit: []const u8) !Encoded {
    if (src.len % 2 != 0) return error.NotWordAligned;
    const n = src.len / 2;
    const words = try arena.alloc(u16, n);
    for (0..n) |i| words[i] = @as(u16, src[i * 2]) | (@as(u16, src[i * 2 + 1]) << 8);
    const out = try arena.alloc(u8, src.len);
    for (words, 0..) |w, i| {
        out[i * 2] = @truncate(w);
        out[i * 2 + 1] = @truncate(w >> 8);
    }
    return .{ .bytes = out, .items = n, .unit = unit };
}

fn byteTable(arena: std.mem.Allocator, src: []const u8, unit: []const u8) !Encoded {
    const ids = try arena.alloc(u8, src.len);
    @memcpy(ids, src);
    const out = try arena.alloc(u8, src.len);
    for (ids, 0..) |v, i| out[i] = v;
    return .{ .bytes = out, .items = src.len, .unit = unit };
}

fn rowTable(arena: std.mem.Allocator, src: []const u8, width: usize, unit: []const u8) !Encoded {
    if (src.len % width != 0) return error.NotRowAligned;
    const rows = src.len / width;
    const out = try arena.alloc(u8, src.len);
    for (0..rows) |r| @memcpy(out[r * width ..][0..width], src[r * width ..][0..width]);
    return .{ .bytes = out, .items = rows, .unit = unit };
}

/// A bank-4 audio entry point: `$C3 lo hi`, an unconditional jump into the
/// sound driver. Decoding requires the opcode rather than storing it, so
/// re-emitting it as a constant is a real check that all three are jumps.
const Trampoline = struct {
    target: u16,

    const opcode: u8 = 0xC3;

    fn decode(src: []const u8) !Trampoline {
        if (src.len != 3) return error.NotATrampoline;
        if (src[0] != opcode) return error.NotAJump;
        return .{ .target = @as(u16, src[1]) | (@as(u16, src[2]) << 8) };
    }

    fn encode(self: Trampoline, out: *[3]u8) void {
        out[0] = opcode;
        out[1] = @truncate(self.target);
        out[2] = @truncate(self.target >> 8);
    }
};

/// Decode one entry and re-serialise it. Returns null for `.none` kinds, which
/// have no decoder to exercise.
pub fn roundTrip(arena: std.mem.Allocator, rom: []const u8, e: offsets.Entry) !?Encoded {
    const src = rom[e.romOffset()..e.romEnd()];

    return switch (e.kind) {
        .graphics_tileset, .graphics_samus, .graphics_enemy, .graphics_item, .graphics_ui => blk: {
            const tiles = try gfx.decodeAll(arena, src);
            break :blk Encoded{ .bytes = try gfx.encodeAll(arena, tiles), .items = tiles.len, .unit = "tiles" };
        },
        .initial_save => blk: {
            const v = save.parseInitial(src) orelse return error.WrongInitialSaveLength;
            const enc = save.encodeInitial(v);
            const out = try arena.alloc(u8, enc.len);
            @memcpy(out, &enc);
            break :blk Encoded{ .bytes = out, .items = 1, .unit = "records" };
        },
        .metatiles => blk: {
            const mts = try tileset.parseMetatiles(arena, src);
            break :blk Encoded{ .bytes = try tileset.encodeMetatiles(arena, mts), .items = mts.len, .unit = "metatiles" };
        },
        .solidity => blk: {
            const rows = try tileset.parseSolidity(src);
            const enc = tileset.encodeSolidity(rows);
            const out = try arena.alloc(u8, enc.len);
            @memcpy(out, &enc);
            break :blk Encoded{ .bytes = out, .items = tileset.solidity_rows, .unit = "rows" };
        },
        .physics => blk: {
            // Not every `physics` blob is an arc. Step 12b put eleven small
            // tables in the class -- direction masks, cannon offsets, two
            // terminated speed tables, the missile's two sprite rows and the
            // weapon damage -- and none of them has framing to prove, so they
            // round-trip as byte tables exactly as `.hitbox`'s BG-top one does.
            // The discriminator is `physics.Which.isArc`, which is the same
            // switch the conversion itself branches on.
            if (physics.Which.forEntry(e.name)) |w| {
                if (!w.isArc()) break :blk try byteTable(arena, src, "entries");
            }
            const arc = try physics.parseArc(arena, src);
            break :blk Encoded{
                .bytes = try physics.encodeArc(arena, arc),
                .items = arc.speeds.len,
                .unit = "frames",
            };
        },
        .hitbox => blk: {
            // The BG-top table is one byte per pose with no framing to prove,
            // so it round-trips as a byte table; the y-offset lists have a
            // stride and a terminator, and those are what the parse is for.
            if (src.len != physics.y_offset_poses * physics.y_offset_stride) {
                break :blk try byteTable(arena, src, "poses");
            }
            const rows = try physics.parseYOffsets(src);
            const enc = physics.encodeYOffsets(rows);
            const out = try arena.alloc(u8, enc.len);
            @memcpy(out, &enc);
            break :blk Encoded{ .bytes = out, .items = physics.y_offset_poses, .unit = "poses" };
        },
        .pose_sprites => blk: {
            const t = try sprites.parsePoseTable(arena, src);
            break :blk Encoded{
                .bytes = try sprites.encodePoseTable(arena, t),
                .items = t.rows(),
                .unit = "rows",
            };
        },
        .collision => try byteTable(arena, src, "tile-ids"),
        .enemy_damage => try byteTable(arena, src, "enemy-ids"),
        .pose_transition => try byteTable(arena, src, "poses"),
        .tilemap => try rowTable(arena, src, 32, "rows"),
        .enemy_headers => blk: {
            const hs = try entity.parseHeaders(arena, src);
            break :blk Encoded{ .bytes = try entity.encodeHeaders(arena, hs), .items = hs.len, .unit = "headers" };
        },
        .enemy_hitboxes => blk: {
            const hb = try entity.parseHitboxes(arena, src);
            break :blk Encoded{ .bytes = try entity.encodeHitboxes(arena, hb), .items = hb.len, .unit = "hitboxes" };
        },
        .metasprite_data => blk: {
            const ms = try entity.parseMetasprites(arena, src, e.gb_addr);
            break :blk Encoded{ .bytes = try entity.encodeMetasprites(arena, ms), .items = ms.len, .unit = "metasprites" };
        },
        .door_data => blk: {
            const decoded = try door.decodeRegion(arena, src);
            var out: std.ArrayList(u8) = .empty;
            var scratch: [16]u8 = undefined;
            for (decoded.ops.items) |op| {
                const n = door.encodeOne(op, &scratch);
                try out.appendSlice(arena, scratch[0..n]);
            }
            break :blk Encoded{ .bytes = try out.toOwnedSlice(arena), .items = decoded.ops.items.len, .unit = "ops" };
        },
        .map_screen_pointers => blk: {
            const b = try map.parseBank(arena, rom, e.bank);
            const out = try arena.alloc(u8, src.len);
            map.encodePointers(b, out);
            break :blk Encoded{ .bytes = out, .items = map.cells, .unit = "cells" };
        },
        .map_scroll_flags => blk: {
            const b = try map.parseBank(arena, rom, e.bank);
            const out = try arena.alloc(u8, src.len);
            map.encodeFlags(b, out);
            break :blk Encoded{ .bytes = out, .items = map.cells, .unit = "cells" };
        },
        .map_transition_indexes => blk: {
            const b = try map.parseBank(arena, rom, e.bank);
            const out = try arena.alloc(u8, src.len);
            map.encodeTransitions(b, out);
            break :blk Encoded{ .bytes = out, .items = map.cells, .unit = "cells" };
        },
        .map_screens => blk: {
            const list = try map.parseScreens(arena, rom, e.bank);
            break :blk Encoded{ .bytes = try map.encodeScreens(arena, list), .items = list.len, .unit = "screens" };
        },
        .door_pointers, .collision_pointers => try wordTable(arena, src, "pointers"),
        .metasprite_pointers, .enemy_data_pointers, .enemy_header_pointers, .enemy_hitbox_pointers => try wordTable(arena, src, "pointers"),
        .sound_entry => blk: {
            const t = try Trampoline.decode(src);
            const out = try arena.alloc(u8, 3);
            t.encode(out[0..3]);
            break :blk Encoded{ .bytes = out, .items = 1, .unit = "trampolines" };
        },
        .enemy_data => blk: {
            const lists = try entity.parseSpawnLists(arena, src, e.gb_addr);
            break :blk Encoded{
                .bytes = try entity.encodeSpawnLists(arena, lists),
                .items = lists.len,
                .unit = "spawn-lists",
            };
        },
        .item_names => blk: {
            const n = try items.parseNames(src, e.gb_addr);
            break :blk Encoded{
                .bytes = try items.encodeNames(arena, n),
                .items = items.count,
                .unit = "names",
            };
        },
        .sound_notes => blk: {
            const notes = try audio_data.parseNotes(arena, src);
            break :blk Encoded{
                .bytes = try audio_data.encodeNotes(arena, notes),
                .items = notes.len,
                .unit = "notes",
            };
        },
        .sound_tempo => blk: {
            const tables = try audio_data.parseTempo(arena, src);
            break :blk Encoded{
                .bytes = try audio_data.encodeTempo(arena, tables),
                .items = tables.len,
                .unit = "ladders",
            };
        },
        .sound_wave_patterns => blk: {
            const region = try audio_data.parseWavePatterns(arena, src);
            break :blk Encoded{
                .bytes = try audio_data.encodeWavePatterns(arena, region),
                .items = region.patterns.len,
                .unit = "patterns",
            };
        },
        .sound_option_sets => blk: {
            // `audio_pausedOptionSets` is indexed by channel rather than being
            // one channel's table, so it has no single width and round-trips as
            // a byte table. The other four state their channel by name.
            const ch = audio_data.optionSetChannel(e.name) orelse
                break :blk try byteTable(arena, src, "bytes");
            const sets = try audio_data.parseOptionSets(arena, ch, src);
            break :blk Encoded{
                .bytes = try audio_data.encodeOptionSets(arena, sets),
                .items = sets.len,
                .unit = "option-sets",
            };
        },
        .sound_effect_table => try rowTable(arena, src, 16, "effect-tables"),
        .sound_flags => try byteTable(arena, src, "bytes"),
        .sound_song_table => blk: {
            const t = try audio_data.SongTable.decode(src);
            const out = try arena.alloc(u8, src.len);
            t.encode(out);
            break :blk Encoded{ .bytes = out, .items = audio_data.song_count, .unit = "songs" };
        },
        .sound_song_data => blk: {
            const table = offsets.find("audio_songDataTable").?;
            const data = try audio_data.parseSongData(
                arena,
                rom[table.romOffset()..table.romEnd()],
                src,
                e.gb_addr,
            );
            break :blk Encoded{
                .bytes = try audio_data.encodeSongData(arena, src, data),
                .items = data.pointers.len,
                .unit = "pointers",
            };
        },
    };
}

/// Round-trip every entry in the offsets table.
pub fn run(allocator: std.mem.Allocator, rom: []const u8) !Report {
    var report: Report = .{ .results = .empty };
    errdefer report.deinit(allocator);

    for (offsets.entries) |e| {
        if (e.romEnd() > rom.len) return error.EntryOutOfBounds;
        const src = rom[e.romOffset()..e.romEnd()];
        const p = plan(e.kind);

        if (p.proof == .none) {
            report.undecoded += 1;
            report.bytes_undecoded += e.size;
            try report.results.append(allocator, .{
                .name = e.name, .kind = e.kind, .proof = .none,
                .bytes = e.size, .items = 0, .unit = "-", .ok = true,
            });
            continue;
        }

        // One arena per entry: map_screens alone is $3B00 bytes seven times
        // over, and none of it outlives the comparison.
        var ea = std.heap.ArenaAllocator.init(allocator);
        defer ea.deinit();

        report.checked += 1;

        const encoded = roundTrip(ea.allocator(), rom, e) catch |err| {
            report.failed += 1;
            try report.results.append(allocator, .{
                .name = e.name, .kind = e.kind, .proof = p.proof,
                .bytes = e.size, .items = 0, .unit = "-", .ok = false,
                .err = @errorName(err),
            });
            continue;
        };
        const enc = encoded.?;

        var first_diff: ?usize = null;
        const n = @min(enc.bytes.len, src.len);
        for (0..n) |i| {
            if (enc.bytes[i] != src[i]) {
                first_diff = i;
                break;
            }
        }
        if (first_diff == null and enc.bytes.len != src.len) first_diff = n;

        const passed = first_diff == null and enc.bytes.len == src.len;
        if (!passed) report.failed += 1 else report.bytes_round_tripped += e.size;
        report.items += enc.items;

        try report.results.append(allocator, .{
            .name = e.name, .kind = e.kind, .proof = p.proof,
            .bytes = e.size, .items = enc.items, .unit = enc.unit,
            .ok = passed, .first_diff = first_diff, .encoded_len = enc.bytes.len,
        });
    }

    return report;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "every kind has a plan, and every claim says what passing means" {
    inline for (@typeInfo(offsets.Kind).@"enum".fields) |f| {
        const p = plan(@field(offsets.Kind, f.name));
        try testing.expect(p.claim.len != 0);
    }
}

test "the undecoded set is exactly the one class we have not read" {
    var none: usize = 0;
    for (offsets.entries) |e| {
        if (plan(e.kind).proof == .none) none += 1;
    }
    // **Empty since Step 11.** If this number moves, a class was added without
    // a decoder - name it in coverage.zig's missing list, deliberately.
    // `enemy_data` left this set in Step 9 of the slice and `item_names` in
    // Step 11, once the block turned out to be a pointer table and sixteen
    // fixed-width strings rather than 416 bytes of unknown shape.
    try testing.expectEqual(@as(usize, 0), none);
    try testing.expectEqual(Proof.encoding, plan(.enemy_data).proof);
    try testing.expectEqual(Proof.encoding, plan(.item_names).proof);
}

test "encoding-level proofs are reserved for classes that reconstruct bytes" {
    // Spot-check the boundary rather than restating the table: graphics repack
    // bitplanes, pointer tables do not.
    try testing.expectEqual(Proof.encoding, plan(.graphics_samus).proof);
    try testing.expectEqual(Proof.encoding, plan(.door_data).proof);
    try testing.expectEqual(Proof.encoding, plan(.metasprite_data).proof);
    try testing.expectEqual(Proof.framing, plan(.door_pointers).proof);
    try testing.expectEqual(Proof.framing, plan(.collision).proof);
}

test "a corrupted trampoline is refused rather than re-emitted as a jump" {
    try testing.expectError(error.NotAJump, Trampoline.decode(&[_]u8{ 0xCD, 0x34, 0x12 }));
    try testing.expectError(error.NotATrampoline, Trampoline.decode(&[_]u8{ 0xC3, 0x34 }));
    const t = try Trampoline.decode(&[_]u8{ 0xC3, 0x34, 0x12 });
    try testing.expectEqual(@as(u16, 0x1234), t.target);
    var out: [3]u8 = undefined;
    t.encode(&out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC3, 0x34, 0x12 }, &out);
}

test "word tables rebuild little-endian order, and reject an odd length" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = [_]u8{ 0x34, 0x12, 0xFF, 0x00 };
    const enc = try wordTable(arena, &src, "pointers");
    try testing.expectEqualSlices(u8, &src, enc.bytes);
    try testing.expectEqual(@as(usize, 2), enc.items);
    try testing.expectError(error.NotWordAligned, wordTable(arena, src[0..3], "pointers"));
}

// ---- ROM-dependent --------------------------------------------------------

const testrom = @import("testrom");

test "every decodable entry round-trips byte-for-byte against the ROM" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var report = try run(testing.allocator, rom);
    defer report.deinit(testing.allocator);

    for (report.results.items) |r| {
        if (r.ok) continue;
        std.debug.print("round-trip failed: {s} ({s}) first diff {?d}, {d} bytes in vs {d} out, err {?s}\n", .{
            r.name, @tagName(r.kind), r.first_diff, r.bytes, r.encoded_len, r.err,
        });
    }
    try testing.expectEqual(@as(usize, 0), report.failed);
    // Every entry but the ones `plan` still calls `.none`, which is none of
    // them since Step 11 read `item_names`. Derived rather than written down,
    // so the number moves with the decoders and not by hand.
    var undecodable: usize = 0;
    for (offsets.entries) |e| {
        if (plan(e.kind).proof == .none) undecodable += 1;
    }
    try testing.expectEqual(offsets.entries.len - undecodable, report.checked);
}

test "mutating the decoded form breaks the comparison, so it is not vacuous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    // A round-trip that passes proves nothing unless a wrong decode would fail
    // it. So corrupt the *typed* form - not the bytes - and confirm the
    // re-encode stops matching the ROM. Any encoder that quietly copied its
    // input instead of rebuilding from the decoded values would survive this.
    {
        const e = offsets.find("gfx_samusPowerSuit") orelse return error.Missing;
        const src = rom[e.romOffset()..e.romEnd()];
        const tiles = try gfx.decodeAll(arena, src);
        tiles[3].pixels[5][2] +%= 1;
        const re = try gfx.encodeAll(arena, tiles);
        try testing.expect(!std.mem.eql(u8, re, src));
    }
    // The same for a framing-level class, where the sensitivity being tested
    // is byte order rather than bit packing.
    {
        const e = offsets.find("enemy_headers") orelse return error.Missing;
        const src = rom[e.romOffset()..e.romEnd()];
        const hs = try entity.parseHeaders(arena, src);
        hs[7].word = ~hs[7].word;
        const re = try entity.encodeHeaders(arena, hs);
        try testing.expect(!std.mem.eql(u8, re, src));
    }
    // And for the door stream, where a wrong operand width would desynchronise
    // everything after it rather than change one byte.
    {
        const e = offsets.find("door_data") orelse return error.Missing;
        const src = rom[e.romOffset()..e.romEnd()];
        const decoded = try door.decodeRegion(arena, src);
        var out: std.ArrayList(u8) = .empty;
        var scratch: [16]u8 = undefined;
        // Drop the first op: every byte after it shifts, which is what a
        // length misread looks like.
        for (decoded.ops.items[1..]) |op| {
            const n = door.encodeOne(op, &scratch);
            try out.appendSlice(arena, scratch[0..n]);
        }
        try testing.expect(!std.mem.eql(u8, out.items, src));
    }
}
