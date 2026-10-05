//! The ARAM image itself: 64 KiB of bytes, from the plan `aram_layout` makes.
//!
//! Step 5 decided *where* everything goes. This puts the bytes there. The
//! result is what the cart uploads through the IPL at boot (Step 16a) and what
//! `vendor/spcrun` runs offline when the comparison harness grades the ported
//! engine against the Game Boy (Step 6).
//!
//! ## Nothing here decides anything
//!
//! Every address comes from `aram_layout.plan`, every shim byte from
//! `audio/shim/shimpkg.zig`, every data byte from the ROM through
//! `audio_data`'s typed readers, and every rewritten pointer from
//! `audio_data.relocate`. This module's whole job is `@memcpy` at the addresses
//! those three agreed on. It is written that way on purpose: an image builder
//! that made its own choice about a placement would be a second, silent opinion
//! about the memory map, and the SPC700 does not complain about a wrong one --
//! it just plays the bytes that happen to be there.
//!
//! ## Why the data is relocated here rather than extracted relocated
//!
//! `audio_data.relocate` needs to know where the three pointer-addressed
//! regions landed, and that is `aram_layout`'s answer, not the ROM's. So the
//! order is fixed: read the ROM's bytes, plan the placement, relocate onto the
//! plan, then copy. An extractor cannot do step three, which is why
//! `extracted/` holds the cartridge's bytes and this holds ARAM's.

const std = @import("std");
const aram_layout = @import("aram_layout.zig");
const audio_data = @import("audio_data.zig");
const offsets = @import("offsets.zig");
const shimpkg = @import("shimpkg");

pub const size: usize = 0x10000;

/// The sentinel `relocateSongTable` puts in the `Nothing` song's slot. It has
/// to be an address the ported engine can test for and never a real header, so
/// it is the top of ARAM: `$FFFF` is inside the IPL ROM's mirror, and no
/// segment this module places can reach it.
pub const song_nothing_sentinel: u16 = 0xFFFF;

pub const Mode = enum {
    /// The engine takes its requests through the ports, one record per tick.
    ///
    /// There is no resident mode here. Resident is the shim playing a captured
    /// log with no engine at all, which `audiobench` builds its own image for;
    /// an image with a ported engine in it is hosted by definition.
    hosted,
    /// Hosted, and every engine register write appended to the trace buffer.
    /// What `audiocmp` grades through.
    hosted_trace,

    fn config(self: Mode) *const [shimpkg.config_size]u8 {
        return switch (self) {
            .hosted => &shimpkg.config_hosted,
            .hosted_trace => &shimpkg.config_hosted_trace,
        };
    }
};

pub const Image = struct {
    bytes: []u8,
    layout: aram_layout.Layout,
    /// Pointer sites `relocate` could not place. Empty on success; `build`
    /// fails before returning a non-empty one, and this is here so a caller
    /// that wants to report them can.
    relocation_errors: []audio_data.RelocationError,

    /// Bytes below the highest segment's end: what the IPL has to upload.
    pub fn uploadSize(self: Image) usize {
        var top: usize = 0;
        for (self.layout.segments) |s| top = @max(top, s.end());
        return top;
    }
};

/// The failures this module raises itself. The readers it calls add their own,
/// so `build`'s error set is inferred rather than written out.
pub const Error = error{
    /// A region overflowed. The caller should call `aram_layout.check` to name
    /// which, so the message is the one Step 5's rung already prints.
    RegionOverflow,
    /// A pointer in the song data addresses nothing that was placed.
    UnplaceablePointer,
    UnknownAudioEntry,
};

/// Build the image. `rom` is the Game Boy cartridge, `engine_code` is
/// `engine/audio.bin`.
pub fn build(
    arena: std.mem.Allocator,
    rom: []const u8,
    engine_code: []const u8,
    mode: Mode,
) !Image {
    const layout = try aram_layout.plan(arena, engine_code.len);
    if (aram_layout.check(layout) != null) return error.RegionOverflow;

    const bytes = try arena.alloc(u8, size);
    @memset(bytes, 0);

    // The shim's own regions, at the addresses the package states.
    for (shimpkg.segments(mode.config(), &aram_layout.dsp_directory)) |s| {
        @memcpy(bytes[s.addr..][0..s.bytes.len], s.bytes);
    }

    @memcpy(bytes[shimpkg.engine_code_addr..][0..engine_code.len], engine_code);

    // Bank 4's data. Most entries are copied as they are; the three that
    // pointers address are relocated first, and the song table's pointers are
    // rewritten to where its headers actually landed.
    const place = layout.placement();
    const song_e = offsets.find("audio_songData") orelse return error.UnknownAudioEntry;
    const table_e = offsets.find("audio_songDataTable") orelse return error.UnknownAudioEntry;
    const tempo_e = offsets.find("audio_tempoTables") orelse return error.UnknownAudioEntry;
    const wave_e = offsets.find("audio_wavePatterns") orelse return error.UnknownAudioEntry;

    // CH3's waves, out of the cartridge's own pattern region: the lookup the
    // shim matches wave RAM against on a trigger, and each wave's BRR at the
    // addresses `aram_layout.dsp_directory` already named. CH4's samples after.
    const wave_src = rom[wave_e.romOffset()..][0..wave_e.size];
    var waves: [aram_layout.wave_offsets.len]shimpkg.wave.Wave = undefined;
    for (&waves, aram_layout.wave_offsets) |*w, off| w.* = wave_src[off..][0..shimpkg.wave.entry_size].*;
    _ = try shimpkg.wave.lut(bytes[shimpkg.wave_lut_addr..][0..aram_layout.wave_lut_size], &waves, shimpkg.Wave.lut_max);
    for (waves, 0..) |w, i| {
        const at = aram_layout.wave_samples_addr + i * shimpkg.wave.bytes_per_wave;
        bytes[at..][0..shimpkg.wave.bytes_per_wave].* = shimpkg.wave.encode(w);
    }
    bytes[aram_layout.noise_samples_addr..][0..shimpkg.noise.bytes].* = shimpkg.noise.encode();

    const song_src = rom[song_e.romOffset()..][0..song_e.size];
    const table_src = rom[table_e.romOffset()..][0..table_e.size];

    const parsed = try audio_data.parseSongData(arena, table_src, song_src, song_e.gb_addr);
    const song_out = try arena.dupe(u8, song_src);
    const errs = try audio_data.relocate(
        arena,
        song_out,
        parsed,
        song_e.gb_addr,
        tempo_e.gb_addr,
        tempo_e.size,
        wave_e.gb_addr,
        wave_e.size,
        place,
    );
    if (errs.len != 0) return error.UnplaceablePointer;

    const table = try audio_data.SongTable.decode(table_src);
    const table_out = try audio_data.relocateSongTable(
        table,
        song_e.gb_addr,
        song_e.size,
        place.song_data,
        song_nothing_sentinel,
    );

    for (layout.segments) |s| {
        if (s.class != .sound_data) continue;
        const dst = bytes[s.addr..][0..s.size];
        if (std.mem.eql(u8, s.name, "audio_songData")) {
            @memcpy(dst, song_out);
        } else if (std.mem.eql(u8, s.name, "audio_songDataTable")) {
            table_out.encode(dst);
        } else if (std.mem.eql(u8, s.name, aram_layout.rom0000_name)) {
            @memcpy(dst, rom[0..s.size]);
        } else {
            // `s.size` carries any overread tail, which is the ROM's next bytes.
            const e = offsets.find(s.name) orelse return error.UnknownAudioEntry;
            @memcpy(dst, rom[e.romOffset()..][0..s.size]);
        }
    }

    return .{ .bytes = bytes, .layout = layout, .relocation_errors = errs };
}

// ---- The upload ------------------------------------------------------------
//
// Step 16a. The cart does not upload 64 KiB, or even the 54 KB up to the
// highest segment's end: it uploads the spans something was placed in, cut into
// blocks the S-SMP's boot ROM can take. `vendor/spcrun` runs the whole image,
// zeroes and all, so every byte the engine can read before writing it has to
// be in a block too -- which is why engine RAM goes up whole rather than as the
// six reply bytes `aram_layout` plans. The hosted bench uploaded one contiguous
// run and got that for free; a sparse upload has to say it.

/// The first address an upload may write. The boot ROM keeps its variables in
/// ARAM's zero page and its stack in page 1 while it takes the upload, so an
/// image written over them never reaches the jump at the end. Everything below
/// is the shim's own state, which it clears at boot.
pub const upload_from: u16 = shimpkg.shim_code_addr;

/// The most data one block carries. Small, because blocks are placed whole
/// into the cart's `aram` region and never across a bank, so the padding a bank
/// boundary costs is at most one block's worth.
pub const block_max: usize = 0x800;

/// Two spans closer than this are uploaded as one, gap included. The gap is
/// zeroes nobody reads; sending them costs less than a block's handshake.
pub const merge_gap: usize = 0x40;

pub const Block = struct {
    aram: u16,
    bytes: []const u8,
};

/// Whether a block of `len` bytes can be followed by another. The boot ROM
/// takes the next block's start on a port 0 value of the last index plus two,
/// and a length ending in $FE makes that zero -- the value it reads as "start
/// sending data" instead. The fed bench found this; the rule is the same one.
pub fn sendableLength(len: usize) bool {
    return len % 0x100 != 0xFE;
}

/// The image's written spans, merged and cut into blocks, in address order.
pub fn uploadBlocks(arena: std.mem.Allocator, img: Image) ![]Block {
    const Span = struct { start: usize, end: usize };
    var spans: std.ArrayList(Span) = .empty;
    for (img.layout.segments) |s| try spans.append(arena, .{ .start = s.addr, .end = s.end() });
    try spans.append(arena, .{ .start = shimpkg.engine_ram_addr, .end = shimpkg.engine_ram_end });
    std.mem.sort(Span, spans.items, {}, struct {
        fn lt(_: void, a: Span, b: Span) bool {
            return a.start < b.start;
        }
    }.lt);

    var merged: std.ArrayList(Span) = .empty;
    for (spans.items) |s| {
        if (s.start < upload_from) return error.SpanBelowUpload;
        if (merged.items.len > 0 and s.start <= merged.items[merged.items.len - 1].end + merge_gap) {
            const last = &merged.items[merged.items.len - 1];
            last.end = @max(last.end, s.end);
        } else try merged.append(arena, s);
    }

    var out: std.ArrayList(Block) = .empty;
    for (merged.items) |s| {
        var at = s.start;
        while (at < s.end) {
            var n = @min(block_max, s.end - at);
            if (!sendableLength(n)) n -= 1;
            try out.append(arena, .{ .aram = @intCast(at), .bytes = img.bytes[at..][0..n] });
            at += n;
        }
    }
    return out.toOwnedSlice(arena);
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the upload covers every segment and all of engine RAM, in sendable blocks" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    const engine = try arena.alloc(u8, 0x1234);
    for (engine, 0..) |*b, i| b.* = @truncate(i | 1);
    const img = try build(arena, rom, engine, .hosted);
    const blocks = try uploadBlocks(arena, img);

    var covered = try arena.alloc(bool, size);
    @memset(covered, false);
    var prev_end: usize = 0;
    for (blocks) |b| {
        try testing.expect(b.aram >= upload_from);
        try testing.expect(b.aram >= prev_end); // ascending, never overlapping
        try testing.expect(b.bytes.len > 0 and b.bytes.len <= block_max);
        try testing.expect(sendableLength(b.bytes.len));
        try testing.expectEqualSlices(u8, img.bytes[b.aram..][0..b.bytes.len], b.bytes);
        for (b.aram..b.aram + b.bytes.len) |i| covered[i] = true;
        prev_end = b.aram + b.bytes.len;
    }
    for (img.layout.segments) |s| {
        for (s.addr..s.end()) |i| try testing.expect(covered[i]);
    }
    for (shimpkg.engine_ram_addr..shimpkg.engine_ram_end) |i| try testing.expect(covered[i]);
    // And sparse: the resident log's span, which hosted mode does not use, is
    // not sent. An upload of everything would pass every check above.
    try testing.expect(!covered[shimpkg.trace_addr + 0x100]);
}

test "a block length ending in $FE is never produced" {
    try testing.expect(!sendableLength(0xFE));
    try testing.expect(!sendableLength(0x1FE));
    try testing.expect(sendableLength(0xFF));
    try testing.expect(sendableLength(block_max));
}
const testrom = @import("testrom");

test "the sentinel is above every region the shim reserves" {
    // If a future shim grew a region up to $FFFF the sentinel would become a
    // real address, and the `Nothing` song would play whatever was there.
    try testing.expect(song_nothing_sentinel > shimpkg.samples_end);
}

test "each mode writes its own configuration block" {
    try testing.expectEqual(shimpkg.mode_hosted, Mode.hosted.config()[shimpkg.Config.mode]);
    try testing.expectEqual(@as(u8, 0), Mode.hosted.config()[shimpkg.Config.flags]);
    try testing.expectEqual(shimpkg.flag_trace, Mode.hosted_trace.config()[shimpkg.Config.flags]);
    try testing.expectEqual(shimpkg.mode_hosted, Mode.hosted_trace.config()[shimpkg.Config.mode]);
}

test "the image carries the shim, the engine and the data at the planned addresses" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    // A stand-in engine, so the test does not need the assembler's output.
    const engine = try arena.alloc(u8, 64);
    for (engine, 0..) |*b, i| b.* = @truncate(i);

    const img = try build(arena, rom, engine, .hosted_trace);
    try testing.expectEqual(size, img.bytes.len);

    // The shim's header, where `spcrun` looks for it.
    try testing.expectEqualSlices(
        u8,
        shimpkg.header_magic,
        img.bytes[shimpkg.header_addr + shimpkg.Header.magic ..][0..4],
    );
    try testing.expectEqual(
        shimpkg.abi_version,
        img.bytes[shimpkg.header_addr + shimpkg.Header.abi_version],
    );
    try testing.expectEqual(shimpkg.mode_hosted, img.bytes[shimpkg.config_addr + shimpkg.Config.mode]);
    try testing.expectEqual(shimpkg.flag_trace, img.bytes[shimpkg.config_addr + shimpkg.Config.flags]);
    try testing.expectEqualSlices(u8, engine, img.bytes[shimpkg.engine_code_addr..][0..engine.len]);

    // Every planned segment's bytes are in the image, and the data segments
    // are not all zero -- an image of zeroes would satisfy every address check.
    for (img.layout.segments) |s| {
        if (s.class != .sound_data) continue;
        var any: bool = false;
        for (img.bytes[s.addr..][0..s.size]) |b| any = any or b != 0;
        try testing.expect(any);
    }
    try testing.expect(img.uploadSize() <= size);
}

test "the song table's pointers land inside the placed song data, and Nothing is the sentinel" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    const img = try build(arena, rom, &.{}, .hosted);

    const seg = img.layout.find("audio_songDataTable").?;
    const data = img.layout.find("audio_songData").?;
    for (0..audio_data.song_count) |id| {
        const p = std.mem.readInt(u16, img.bytes[seg.addr + id * 2 ..][0..2], .little);
        if (id == audio_data.song_nothing_index) {
            try testing.expectEqual(song_nothing_sentinel, p);
            continue;
        }
        try testing.expect(p >= data.addr and p < data.end());
    }
}

test "a note past musicNotes' end reads what the Game Boy reads there" {
    // `loadNextSound` indexes `musicNotes` by the note byte plus `songTranspose`,
    // eight bits and unbounded, so any of the 256 indexes (and the high byte
    // after the last one) must be the ROM's bytes. A layout that put anything
    // else after the table grades exact on title and surface, and fails
    // subCaves3 at its first wave note.
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    const img = try build(arena, rom, &.{}, .hosted);

    const notes = img.layout.find("audio_musicNotes").?;
    const off = offsets.find("audio_musicNotes").?.romOffset();
    try testing.expectEqualSlices(u8, rom[off..][0..0x101], img.bytes[notes.addr..][0..0x101]);
}

test "table $A's index $10 reads the ROM's byte after the effect tables" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    const img = try build(arena, rom, &.{}, .hosted);

    const tables = img.layout.find("audio_songEffectTables").?;
    const e = offsets.find("audio_songEffectTables").?;
    try testing.expectEqual(@as(u8, 0xFA), rom[e.romOffset() + 0x50]);
    try testing.expectEqual(rom[e.romOffset() + 0x50], img.bytes[tables.addr + 0x50]);
}

test "every overread tail, and rom0000, hold the ROM's bytes" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    const img = try build(arena, rom, &.{}, .hosted);

    for (aram_layout.overreads) |o| {
        const s = img.layout.find(o.entry).?;
        const e = offsets.find(o.entry).?;
        try testing.expectEqualSlices(u8, rom[e.romEnd()..][0..o.bytes], img.bytes[s.addr + e.size ..][0..o.bytes]);
    }
    const z = img.layout.find(aram_layout.rom0000_name).?;
    try testing.expectEqual(@as(usize, 16), z.size);
    try testing.expectEqualSlices(u8, rom[0..16], img.bytes[z.addr..][0..z.size]);
    // The four the `$F5` repeat reads, as a list: a length, a note, a rest and
    // its end.
    try testing.expectEqualSlices(u8, &.{ 0xC3, 0xFB, 0x01, 0x00 }, img.bytes[z.addr..][0..4]);
}
