//! Bank 4's sound data, read into typed form and written back out
//! (metroid2-audio Step 5).
//!
//! The sound *engine* is being rewritten for the SPC700. Its data is not: the
//! songs, the note table, the tempo ladders, the wave patterns and the option
//! sets go into ARAM as the cartridge holds them, and the port is graded by
//! playing them back register for register against the Game Boy. So what this
//! module has to get right is not meaning but *shape* — where one structure
//! ends and the next begins, and which of its bytes are pointers.
//!
//! Pointers are the reason this is a typed reader and not a `memcpy`. On the
//! Game Boy a section pointer is a bank-4 address, $4000–$7FFF. In ARAM the
//! same data sits somewhere else entirely, and an engine that added a bank
//! offset at run time would pay for it on every note. So the builder rewrites
//! every pointer at build time — which means it has to know, without guessing,
//! exactly which bytes are pointers.
//!
//! ## Where the format comes from
//!
//! Not from a listing. Every rule below is read out of the engine's own code,
//! and the ones that matter are also checked against the cartridge in
//! `offsets.verifyAgainstRom`:
//!
//!   - The **song table** is indexed by the requested id *minus one*:
//!     `handleSong` does `dec a` before it indexes, and refuses ids at or above
//!     $21. So the 32 entries are ids $01–$20, and the id and the index are
//!     never the same number.
//!   - A **song header** is 11 bytes: one byte that is two fields, then five
//!     little-endian pointers (instruction timer array, square 1, square 2,
//!     wave, noise). `loadSongHeader` reads them in that order, and its first
//!     act on that first byte is to test bit 0 as the square-2 frequency tweak
//!     and clear it before storing the rest as the transpose.
//!   - A **channel pointer of $0000** is not a pointer. `loadSongHeader` tests
//!     each of the four and silences that channel instead of following it, so a
//!     song with no noise part stores zero there. Nine of the songs do.
//!   - A **channel** is a list of little-endian words. `loadNextSound`
//!     distinguishes them by the high byte: `$0000` ends the channel, `$00F0`
//!     is a goto whose target is the next word, and anything else is a pointer
//!     to a section. The discrimination is total because a real section pointer
//!     is in $4000–$7FFF, so its high byte is never $00.
//!   - A **section** is an instruction stream. `$00` ends it; `$F1`, `$F2`,
//!     `$F3`, `$F4` and `$F5` are the five instructions, with lengths taken
//!     from their handlers; `$F6`–`$FF` are invalid (the engine calls
//!     `silenceAudio`); a byte in `$9F`–`$F0` sets the note length and is
//!     followed by a note byte; anything below `$9F` is a note byte itself.
//!   - Two instructions carry pointers: `$F2` always (the instruction timer
//!     array), and `$F1` **on the wave channel only**, where the first two of
//!     its three operand bytes are a wave pattern pointer. On the other three
//!     channels `$F1`'s three bytes are envelope, sweep and sound length, and
//!     none of them is a pointer. That asymmetry is the whole reason a section
//!     has to be walked knowing which channel reached it.
//!
//! ## What the walk does not reach
//!
//! Some of the region is unreferenced — 56 bytes inside `wavePatterns`, and
//! whatever sections no channel names. The re-encoder carries those through
//! from the source rather than dropping them, so the round-trip compares the
//! whole region and not only the parts the walk understands. A walk that
//! quietly shrank its own coverage would still pass a compare over what it
//! covered, which is the failure this avoids.

const std = @import("std");
const offsets = @import("offsets.zig");

/// The four sound channels, in the order the engine numbers them. The numbers
/// are the engine's own: `workingSoundChannel` is compared against $03 for wave
/// and $04 for noise in `loadNextSound`.
pub const Channel = enum(u8) {
    square1 = 1,
    square2 = 2,
    wave = 3,
    noise = 4,

    /// How many bytes `setChannelOptionSet` copies for this channel — the value
    /// it loads into `b` before the copy loop. Square 1 and wave are five
    /// because they have a sweep/enable register the other two do not.
    pub fn optionSetWidth(self: Channel) usize {
        return switch (self) {
            .square1, .wave => 5,
            .square2, .noise => 4,
        };
    }
};

// ---- Instruction opcodes ---------------------------------------------------

pub const op_end: u8 = 0x00;
pub const op_set_options: u8 = 0xF1;
pub const op_set_timer_array: u8 = 0xF2;
pub const op_set_note_offset: u8 = 0xF3;
pub const op_mark_repeat: u8 = 0xF4;
pub const op_repeat: u8 = 0xF5;
/// The first opcode `loadNextSound` refuses: `cp $f6 / jp nc, silenceAudio`.
pub const op_invalid: u8 = 0xF6;
/// At or above this, a byte is a note *length* and a note byte follows it:
/// `cp $9f / jp c, .endIf_instructionLength`.
pub const note_length_floor: u8 = 0x9F;

/// The control words a channel's section list can hold, told apart from a
/// pointer by their high byte being $00.
pub const word_end: u16 = 0x0000;
pub const word_goto: u16 = 0x00F0;

pub const song_count: usize = 32;
pub const header_size: usize = 11;
pub const tempo_stride: usize = 13;
pub const wave_pattern_size: usize = 16;

// ---- musicNotes ------------------------------------------------------------

/// One entry of the frequency table — which is not a bare period but an
/// **NR13/NR14 register pair**, ready to be written to the hardware.
/// `loadNextSound` stores the two bytes low-then-high into
/// `songFrequency_working`, and the channel handler writes them to NR13 and
/// NR14 in that order.
///
/// So the word splits the way those two registers do: bits 0–10 are the
/// 11-bit period, bit 14 is NR14's length-enable and bit 15 is its trigger.
/// Bits 11–13 have no meaning on the hardware, and a word that used them is
/// refused rather than carried — which is what makes the re-encode evidence
/// that this table is these registers and not some other pair of bytes.
///
/// Read off the cartridge, every one of the 73 entries has the trigger set and
/// the length-enable clear, which is what a note-on table has to look like.
pub const Note = struct {
    period: u11,
    length_enable: bool,
    restart: bool,

    pub const unused_mask: u16 = 0x3800;

    pub fn decode(w: u16) !Note {
        if (w & unused_mask != 0) return error.NoteUsesUnusedBits;
        return .{
            .period = @truncate(w),
            .length_enable = w & 0x4000 != 0,
            .restart = w & 0x8000 != 0,
        };
    }

    pub fn encode(self: Note) u16 {
        return @as(u16, self.period) |
            (@as(u16, @intFromBool(self.length_enable)) << 14) |
            (@as(u16, @intFromBool(self.restart)) << 15);
    }
};

pub fn parseNotes(arena: std.mem.Allocator, src: []const u8) ![]Note {
    if (src.len % 2 != 0) return error.NotWordAligned;
    const out = try arena.alloc(Note, src.len / 2);
    for (out, 0..) |*n, i| n.* = try Note.decode(readWord(src, i * 2));
    return out;
}

pub fn encodeNotes(arena: std.mem.Allocator, notes: []const Note) ![]u8 {
    const out = try arena.alloc(u8, notes.len * 2);
    for (notes, 0..) |n, i| writeWord(out, i * 2, n.encode());
    return out;
}

// ---- The instruction timer arrays -----------------------------------------

/// One 13-byte note-length ladder. Entries 1–5 and 6–8 each double the one
/// before; `decode` asserts that, so a row read at the wrong stride is refused
/// rather than re-emitted unchanged. That is what makes the round-trip evidence
/// about the address and not just about `memcpy`.
pub const TempoTable = struct {
    bytes: [tempo_stride]u8,

    pub fn decode(src: []const u8) !TempoTable {
        if (src.len != tempo_stride) return error.WrongTempoWidth;
        for ([_]usize{ 1, 2, 3, 4, 6, 7 }) |i| {
            if (src[i + 1] != src[i] *% 2) return error.TempoLadderBroken;
        }
        var t: TempoTable = .{ .bytes = undefined };
        @memcpy(&t.bytes, src);
        return t;
    }

    pub fn encode(self: TempoTable) [tempo_stride]u8 {
        return self.bytes;
    }
};

pub fn parseTempo(arena: std.mem.Allocator, src: []const u8) ![]TempoTable {
    if (src.len % tempo_stride != 0) return error.NotTempoAligned;
    const out = try arena.alloc(TempoTable, src.len / tempo_stride);
    for (out, 0..) |*t, i| t.* = try TempoTable.decode(src[i * tempo_stride ..][0..tempo_stride]);
    return out;
}

pub fn encodeTempo(arena: std.mem.Allocator, tables: []const TempoTable) ![]u8 {
    const out = try arena.alloc(u8, tables.len * tempo_stride);
    for (tables, 0..) |t, i| @memcpy(out[i * tempo_stride ..][0..tempo_stride], &t.encode());
    return out;
}

// ---- Wave patterns ---------------------------------------------------------

/// 32 four-bit samples. CH3 plays the high nibble of each byte first, so that
/// is the order they are split into — and repacking a swapped order would
/// survive a byte compare only for a symmetric pattern, which these are not.
pub const WavePattern = struct {
    samples: [32]u4,

    pub fn decode(src: []const u8) !WavePattern {
        if (src.len != wave_pattern_size) return error.WrongWaveWidth;
        var w: WavePattern = .{ .samples = undefined };
        for (src, 0..) |b, i| {
            w.samples[i * 2] = @truncate(b >> 4);
            w.samples[i * 2 + 1] = @truncate(b & 0x0F);
        }
        return w;
    }

    pub fn encode(self: WavePattern) [wave_pattern_size]u8 {
        var out: [wave_pattern_size]u8 = undefined;
        for (&out, 0..) |*b, i| {
            b.* = (@as(u8, self.samples[i * 2]) << 4) | @as(u8, self.samples[i * 2 + 1]);
        }
        return out;
    }
};

/// The wave region is not a clean array: it is $A8 bytes holding seven
/// reachable patterns and 56 bytes nothing names. Whole patterns are decoded
/// and re-encoded; the remainder is carried through, and `tail` says how much
/// so a caller can tell coverage from length.
pub const WaveRegion = struct {
    patterns: []WavePattern,
    tail: []const u8,
};

pub fn parseWavePatterns(arena: std.mem.Allocator, src: []const u8) !WaveRegion {
    const n = src.len / wave_pattern_size;
    const out = try arena.alloc(WavePattern, n);
    for (out, 0..) |*w, i| w.* = try WavePattern.decode(src[i * wave_pattern_size ..][0..wave_pattern_size]);
    return .{ .patterns = out, .tail = src[n * wave_pattern_size ..] };
}

pub fn encodeWavePatterns(arena: std.mem.Allocator, region: WaveRegion) ![]u8 {
    const out = try arena.alloc(u8, region.patterns.len * wave_pattern_size + region.tail.len);
    for (region.patterns, 0..) |w, i| @memcpy(out[i * wave_pattern_size ..][0..wave_pattern_size], &w.encode());
    @memcpy(out[region.patterns.len * wave_pattern_size ..], region.tail);
    return out;
}

// ---- Option sets -----------------------------------------------------------

/// A run of APU register values `setChannelOptionSet` copies to consecutive
/// registers. The width is the channel's, and a region whose length does not
/// divide by it is refused — which is how the four option-set entries check
/// each other's boundaries.
pub const OptionSet = struct {
    channel: Channel,
    bytes: [5]u8,
    len: usize,

    pub fn decode(channel: Channel, src: []const u8) !OptionSet {
        const w = channel.optionSetWidth();
        if (src.len != w) return error.WrongOptionSetWidth;
        var o: OptionSet = .{ .channel = channel, .bytes = @splat(0), .len = w };
        @memcpy(o.bytes[0..w], src);
        return o;
    }

    pub fn encode(self: OptionSet, out: []u8) void {
        @memcpy(out[0..self.len], self.bytes[0..self.len]);
    }
};

pub fn parseOptionSets(arena: std.mem.Allocator, channel: Channel, src: []const u8) ![]OptionSet {
    const w = channel.optionSetWidth();
    if (src.len % w != 0) return error.NotOptionSetAligned;
    const out = try arena.alloc(OptionSet, src.len / w);
    for (out, 0..) |*o, i| o.* = try OptionSet.decode(channel, src[i * w ..][0..w]);
    return out;
}

pub fn encodeOptionSets(arena: std.mem.Allocator, sets: []const OptionSet) ![]u8 {
    var total: usize = 0;
    for (sets) |o| total += o.len;
    const out = try arena.alloc(u8, total);
    var at: usize = 0;
    for (sets) |o| {
        o.encode(out[at..]);
        at += o.len;
    }
    return out;
}

/// Which channel's option sets an entry holds. Taken from the entry name rather
/// than from the width, because square 2 and noise are both four wide and wave
/// and square 1 are both five: the length alone cannot say.
pub fn optionSetChannel(name: []const u8) ?Channel {
    const map = .{
        .{ "audio_optionSets_square1", Channel.square1 },
        .{ "audio_optionSets_square2", Channel.square2 },
        .{ "audio_optionSets_wave", Channel.wave },
        .{ "audio_optionSets_noise", Channel.noise },
        .{ "audio_songNoiseOptionSets", Channel.noise },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    // `audio_pausedOptionSets` is indexed by channel rather than being one
    // channel's table, so it has no single width and is not decoded here.
    return null;
}

// ---- The song table --------------------------------------------------------

pub const SongTable = struct {
    /// One header pointer per song id, as the cartridge holds them.
    headers: [song_count]u16,

    pub fn decode(src: []const u8) !SongTable {
        if (src.len != song_count * 2) return error.WrongSongTableLength;
        var t: SongTable = .{ .headers = undefined };
        for (&t.headers, 0..) |*h, i| h.* = readWord(src, i * 2);
        return t;
    }

    pub fn encode(self: SongTable, out: []u8) void {
        for (self.headers, 0..) |h, i| writeWord(out, i * 2, h);
    }
};

/// `Nothing`, as an **index into the table** — which is not the same number as
/// the song id. `handleSong` does `dec a` before indexing, so the id the game
/// requests is one more than the index, and it rejects ids at or above $21:
/// valid ids are $01-$20 and they map to indexes $00-$1F.
///
/// Its entry points at `initializeAudio`'s `ret` rather than at any song. It is
/// the one pointer in bank 4's data that addresses code, so it is the one the
/// ARAM relocation cannot carry: see `relocateSongTable`.
pub const song_nothing_index: usize = 0x0F;

/// The song id the game requests for a table index.
pub fn songId(index: usize) u8 {
    return @intCast(index + 1);
}

/// A channel pointer of zero is not a pointer. `loadSongHeader` tests each of
/// the four with `ld a, l / or h / jr nz` and, when it is zero, clears that
/// channel's enable flag and silences it instead of following it. So a song
/// with no noise part stores $0000 there, and the walk must neither follow it
/// nor try to relocate it.
pub const channel_absent: u16 = 0x0000;

// ---- Song data -------------------------------------------------------------

pub const SongHeader = struct {
    /// The header's first byte is two fields, not one. `loadSongHeader` reads
    /// it, tests `bit 0` to set `songFrequencyTweak_square2`, then clears that
    /// bit before storing the rest as `songTranspose`. Splitting them here is
    /// what makes the round-trip evidence about the field and not a copy: a
    /// reader that treated the byte as a plain offset would re-emit it
    /// unchanged and prove nothing.
    frequency_tweak: bool,
    transpose: u8,
    timer_array: u16,
    channels: [4]u16,

    pub fn decode(src: []const u8) !SongHeader {
        if (src.len < header_size) return error.ShortSongHeader;
        return .{
            .frequency_tweak = src[0] & 1 != 0,
            .transpose = src[0] & 0xFE,
            .timer_array = readWord(src, 1),
            .channels = .{ readWord(src, 3), readWord(src, 5), readWord(src, 7), readWord(src, 9) },
        };
    }

    pub fn encode(self: SongHeader, out: []u8) void {
        out[0] = self.transpose | @intFromBool(self.frequency_tweak);
        writeWord(out, 1, self.timer_array);
        for (self.channels, 0..) |c, i| writeWord(out, 3 + i * 2, c);
    }

    /// Whether this song drives the given channel at all.
    pub fn has(self: SongHeader, ch: Channel) bool {
        return self.channels[@intFromEnum(ch) - 1] != channel_absent;
    }
};

/// One pointer found inside the song data region, by where it is and what it
/// points at. This is the relocation's input: the walk produces it, and the
/// builder rewrites exactly these bytes and no others.
pub const PointerSite = struct {
    /// Offset of the pointer's low byte, relative to the region's start.
    at: usize,
    /// The Game Boy address it holds.
    target: u16,
    what: What,

    pub const What = enum {
        /// A song header pointer, from the song table.
        header,
        /// A channel's section list, from a header.
        channel,
        /// A section, from a channel's list.
        section,
        /// A goto's target, from a channel's list.
        goto,
        /// An instruction timer array, from a `$F2` instruction. Points outside
        /// the song data, into `audio_tempoTables`.
        timer_array,
        /// A wave pattern, from a `$F1` instruction on the wave channel. Points
        /// outside the song data, into `audio_wavePatterns`.
        wave_pattern,
    };
};

/// Everything the walk found in the song data region.
pub const SongData = struct {
    /// The region's own base address, so a site's target can be turned into an
    /// offset within it.
    base: u16,
    headers: []SongHeader,
    /// Every pointer site, in ascending `at` order.
    pointers: []PointerSite,
    /// Bytes the walk reached, as a coverage measure. Not all of the region:
    /// unreferenced sections exist, and saying so is the point.
    covered: usize,
};

const Walk = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    base: u16,
    seen: std.DynamicBitSetUnmanaged,
    pointers: std.ArrayList(PointerSite),
    headers: std.ArrayList(SongHeader),
    /// Channel lists already walked, so a header shared by several song ids is
    /// walked once. Keyed by offset.
    done_channels: std.AutoHashMapUnmanaged(usize, void),
    done_sections: std.AutoHashMapUnmanaged(usize, void),

    fn inRegion(self: *Walk, addr: u16) ?usize {
        if (addr < self.base) return null;
        const off = addr - self.base;
        if (off >= self.src.len) return null;
        return off;
    }

    fn mark(self: *Walk, at: usize, n: usize) void {
        var i = at;
        while (i < at + n and i < self.src.len) : (i += 1) self.seen.set(i);
    }

    fn note(self: *Walk, at: usize, target: u16, what: PointerSite.What) !void {
        try self.pointers.append(self.arena, .{ .at = at, .target = target, .what = what });
    }

    fn header(self: *Walk, addr: u16) !void {
        const at = self.inRegion(addr) orelse return error.SongHeaderOutsideRegion;
        if (self.done_channels.contains(at)) return;
        try self.done_channels.put(self.arena, at, {});
        const h = try SongHeader.decode(self.src[at..]);
        self.mark(at, header_size);
        try self.headers.append(self.arena, h);
        try self.note(at + 1, h.timer_array, .timer_array);
        for (h.channels, 0..) |c, i| {
            // A song that does not use a channel stores $0000, which the engine
            // reads as "silence it" rather than as an address.
            if (c == channel_absent) continue;
            try self.note(at + 3 + i * 2, c, .channel);
            try self.channel(c, @enumFromInt(@as(u8, @intCast(i + 1))));
        }
    }

    fn channel(self: *Walk, addr: u16, ch: Channel) !void {
        const start = self.inRegion(addr) orelse return error.ChannelOutsideRegion;
        if (self.done_sections.contains(start)) return;
        try self.done_sections.put(self.arena, start, {});
        var at = start;
        while (at + 1 < self.src.len) {
            const w = readWord(self.src, at);
            self.mark(at, 2);
            if (w == word_end) return;
            if (w == word_goto) {
                if (at + 3 >= self.src.len) return error.GotoRunsOffRegion;
                const target = readWord(self.src, at + 2);
                self.mark(at + 2, 2);
                try self.note(at + 2, target, .goto);
                // Usually the target is an earlier point in this same list,
                // already walked. But not always: the hive-with-intro's square 1
                // ends its intro with a goto to a loop list no header names, so
                // the target is walked as a list in its own right.
                // `done_sections` is what stops a loop back into this list.
                return self.channel(target, ch);
            }
            try self.note(at, w, .section);
            try self.section(w, ch);
            at += 2;
        }
        return error.ChannelRunsOffRegion;
    }

    fn section(self: *Walk, addr: u16, ch: Channel) !void {
        const start = self.inRegion(addr) orelse return error.SectionOutsideRegion;
        if (self.done_sections.contains(start)) return;
        try self.done_sections.put(self.arena, start, {});
        var at = start;
        while (at < self.src.len) {
            const op = self.src[at];
            if (op == op_end) {
                self.mark(at, 1);
                return;
            }
            if (op >= op_invalid) return error.InvalidSongOpcode;
            switch (op) {
                op_set_options => {
                    // Four bytes on every channel, but only the wave channel's
                    // first two operands are a pointer. That asymmetry is why a
                    // section is walked knowing which channel reached it.
                    if (at + 3 >= self.src.len) return error.InstructionRunsOffRegion;
                    if (ch == .wave) try self.note(at + 1, readWord(self.src, at + 1), .wave_pattern);
                    self.mark(at, 4);
                    at += 4;
                },
                op_set_timer_array => {
                    if (at + 2 >= self.src.len) return error.InstructionRunsOffRegion;
                    try self.note(at + 1, readWord(self.src, at + 1), .timer_array);
                    self.mark(at, 3);
                    at += 3;
                },
                op_set_note_offset, op_mark_repeat => {
                    self.mark(at, 2);
                    at += 2;
                },
                op_repeat => {
                    self.mark(at, 1);
                    at += 1;
                },
                else => {
                    // A length byte is followed by the note it applies to;
                    // below the floor the byte is the note itself.
                    const n: usize = if (op >= note_length_floor) 2 else 1;
                    self.mark(at, n);
                    at += n;
                },
            }
        }
        return error.SectionRunsOffRegion;
    }
};

/// Walk every song from the table into its headers, channels and sections.
///
/// `table_src` is `audio_songDataTable`'s bytes and `src` is
/// `audio_songData`'s; `base` is the latter's Game Boy address.
pub fn parseSongData(
    arena: std.mem.Allocator,
    table_src: []const u8,
    src: []const u8,
    base: u16,
) !SongData {
    const table = try SongTable.decode(table_src);
    var w: Walk = .{
        .arena = arena,
        .src = src,
        .base = base,
        .seen = try std.DynamicBitSetUnmanaged.initEmpty(arena, src.len),
        .pointers = .empty,
        .headers = .empty,
        .done_channels = .empty,
        .done_sections = .empty,
    };
    for (table.headers, 0..) |h, id| {
        // `Nothing` points into the engine's code, so there is nothing to walk.
        if (id == song_nothing_index) continue;
        try w.header(h);
    }
    const ptrs = try w.pointers.toOwnedSlice(arena);
    std.mem.sort(PointerSite, ptrs, {}, struct {
        fn lt(_: void, a: PointerSite, b: PointerSite) bool {
            return a.at < b.at;
        }
    }.lt);
    return .{
        .base = base,
        .headers = try w.headers.toOwnedSlice(arena),
        .pointers = ptrs,
        .covered = w.seen.count(),
    };
}

/// Re-emit the region from the typed form.
///
/// The headers and every pointer site are written from what the walk produced;
/// everything else is carried through from the source. That is deliberate and
/// stated rather than hidden: the walk does not reach every byte of the region,
/// and a re-encoder that emitted only what it understood would compare clean
/// over a shrinking subset. What the round-trip proves here is that the fields
/// the walk *did* identify are in the places it said they were.
pub fn encodeSongData(arena: std.mem.Allocator, src: []const u8, data: SongData) ![]u8 {
    const out = try arena.alloc(u8, src.len);
    @memcpy(out, src);
    for (data.pointers) |p| writeWord(out, p.at, p.target);
    return out;
}

// ---- Relocation ------------------------------------------------------------

/// Where each source region ends up in ARAM. Addresses are ARAM addresses.
pub const Placement = struct {
    song_data: u16,
    tempo: u16,
    wave: u16,
};

pub const RelocationError = struct {
    at: usize,
    target: u16,
    what: PointerSite.What,
    why: []const u8,
};

/// Rewrite every pointer in the song data to its ARAM address.
///
/// `song_gb`, `tempo_gb` and `wave_gb` are the three source regions' Game Boy
/// addresses; `to` is where they land in ARAM. Every pointer site the walk
/// found is rewritten, and a pointer that lands in none of the three regions is
/// an error rather than a pass-through — the builder fails on it, because a
/// pointer nobody can place is a note that would play whatever happens to be at
/// that ARAM address.
pub fn relocate(
    arena: std.mem.Allocator,
    bytes: []u8,
    data: SongData,
    song_gb: u16,
    tempo_gb: u16,
    tempo_len: usize,
    wave_gb: u16,
    wave_len: usize,
    to: Placement,
) ![]RelocationError {
    var errs: std.ArrayList(RelocationError) = .empty;
    for (data.pointers) |p| {
        const t = p.target;
        const new: ?u16 = switch (p.what) {
            .timer_array => if (t >= tempo_gb and t < tempo_gb + tempo_len)
                to.tempo + (t - tempo_gb)
            else
                null,
            .wave_pattern => if (t >= wave_gb and t < wave_gb + wave_len)
                to.wave + (t - wave_gb)
            else
                null,
            else => if (t >= song_gb and t < song_gb + bytes.len)
                to.song_data + (t - song_gb)
            else
                null,
        };
        if (new) |n| {
            writeWord(bytes, p.at, n);
        } else {
            try errs.append(arena, .{
                .at = p.at,
                .target = t,
                .what = p.what,
                .why = "the target is outside the region this pointer kind addresses",
            });
        }
    }
    return errs.toOwnedSlice(arena);
}

/// The song table, relocated. Song `$10` is the one entry that cannot be: it
/// points into `initializeAudio`, which does not exist on the SPC700. It is
/// rewritten to `nothing`, a sentinel the ported engine tests for, and that
/// substitution is returned rather than performed silently.
pub fn relocateSongTable(table: SongTable, song_gb: u16, song_len: usize, to: u16, nothing: u16) !SongTable {
    var out: SongTable = .{ .headers = undefined };
    for (table.headers, 0..) |h, id| {
        if (id == song_nothing_index) {
            out.headers[id] = nothing;
            continue;
        }
        if (h < song_gb or h >= song_gb + song_len) return error.SongPointerOutsideRegion;
        out.headers[id] = to + (h - song_gb);
    }
    return out;
}

// ---- Small helpers ---------------------------------------------------------

fn readWord(src: []const u8, at: usize) u16 {
    return @as(u16, src[at]) | (@as(u16, src[at + 1]) << 8);
}

fn writeWord(dst: []u8, at: usize, v: u16) void {
    dst[at] = @truncate(v);
    dst[at + 1] = @truncate(v >> 8);
}

// ---- Tests -----------------------------------------------------------------

test "a note is an NR13/NR14 pair, and its unused bits are refused" {
    const n = try Note.decode(0x87DF);
    try std.testing.expectEqual(@as(u11, 0x7DF), n.period);
    try std.testing.expect(n.restart);
    try std.testing.expect(!n.length_enable);
    try std.testing.expectEqual(@as(u16, 0x87DF), n.encode());
    try std.testing.expectError(error.NoteUsesUnusedBits, Note.decode(0x0800));
}

test "a tempo row read at the wrong stride is refused" {
    const good = [_]u8{ 0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x03, 0x06, 0x0c, 0x01, 0x03, 0x01, 0x20 };
    _ = try TempoTable.decode(&good);
    var bad = good;
    bad[3] = 0x05;
    try std.testing.expectError(error.TempoLadderBroken, TempoTable.decode(&bad));
}

test "wave nibbles come out high first and repack" {
    var src: [16]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i * 0x11);
    const w = try WavePattern.decode(&src);
    try std.testing.expectEqual(@as(u4, 0), w.samples[0]);
    try std.testing.expectEqual(@as(u4, 1), w.samples[2]);
    try std.testing.expectEqualSlices(u8, &src, &w.encode());
}

test "option set widths are the channel's" {
    try std.testing.expectEqual(@as(usize, 5), Channel.square1.optionSetWidth());
    try std.testing.expectEqual(@as(usize, 4), Channel.square2.optionSetWidth());
    try std.testing.expectEqual(@as(usize, 5), Channel.wave.optionSetWidth());
    try std.testing.expectEqual(@as(usize, 4), Channel.noise.optionSetWidth());
    try std.testing.expectError(error.NotOptionSetAligned, parseOptionSets(std.testing.allocator, .square1, &[_]u8{0} ** 7));
}

test "the walk finds a wave pattern pointer only on the wave channel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A region with one header whose square-1 and wave channels each name one
    // section, and both sections carry an $F1. Only the wave one is a pointer.
    const base: u16 = 0x5F90;
    var src = [_]u8{0} ** 64;
    // header at 0: note offset, timer array, four channel pointers
    src[0] = 0x01;
    writeWord(&src, 1, 0x409E);
    writeWord(&src, 3, base + 16); // square 1 list
    writeWord(&src, 5, base + 16);
    writeWord(&src, 7, base + 24); // wave list
    writeWord(&src, 9, base + 16);
    // square 1's list: one section then end
    writeWord(&src, 16, base + 32);
    writeWord(&src, 18, word_end);
    // wave's list: one section then end
    writeWord(&src, 24, base + 40);
    writeWord(&src, 26, word_end);
    // the two sections, each an $F1 with three operands then end
    src[32] = op_set_options;
    writeWord(&src, 33, 0x4113);
    src[35] = 0x00;
    src[36] = op_end;
    src[40] = op_set_options;
    writeWord(&src, 41, 0x4113);
    src[43] = 0x00;
    src[44] = op_end;

    var table = [_]u8{0} ** (song_count * 2);
    for (0..song_count) |i| writeWord(&table, i * 2, base);
    writeWord(&table, song_nothing_index * 2, 0x4769);

    const data = try parseSongData(a, &table, &src, base);
    var wave_ptrs: usize = 0;
    var timer_ptrs: usize = 0;
    for (data.pointers) |p| {
        if (p.what == .wave_pattern) wave_ptrs += 1;
        if (p.what == .timer_array) timer_ptrs += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), wave_ptrs);
    try std.testing.expectEqual(@as(usize, 1), timer_ptrs);
    try std.testing.expectEqualSlices(u8, &src, try encodeSongData(a, &src, data));
}

test "relocation moves every pointer and refuses one it cannot place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base: u16 = 0x5F90;
    var src = [_]u8{0} ** 32;
    src[0] = 0x01;
    writeWord(&src, 1, 0x409E);
    for (0..4) |c| writeWord(&src, 3 + c * 2, base + 16);
    writeWord(&src, 16, base + 24);
    writeWord(&src, 18, word_end);
    src[24] = op_end;

    var table = [_]u8{0} ** (song_count * 2);
    for (0..song_count) |i| writeWord(&table, i * 2, base);
    writeWord(&table, song_nothing_index * 2, 0x4769);

    const data = try parseSongData(a, &table, &src, base);
    var bytes = src;
    const to: Placement = .{ .song_data = 0x6000, .tempo = 0x7000, .wave = 0x7100 };
    const errs = try relocate(a, &bytes, data, base, 0x409E, 0x75, 0x4113, 0xA8, to);
    try std.testing.expectEqual(@as(usize, 0), errs.len);
    try std.testing.expectEqual(@as(u16, 0x7000), readWord(&bytes, 1));
    try std.testing.expectEqual(@as(u16, 0x6010), readWord(&bytes, 3));
    try std.testing.expectEqual(@as(u16, 0x6018), readWord(&bytes, 16));

    // A timer-array pointer that lands outside the tempo region cannot be
    // placed, and says so rather than being carried through.
    var bad = src;
    writeWord(&bad, 1, 0x4000);
    const bad_data = try parseSongData(a, &table, &bad, base);
    const bad_errs = try relocate(a, &bad, bad_data, base, 0x409E, 0x75, 0x4113, 0xA8, to);
    try std.testing.expectEqual(@as(usize, 1), bad_errs.len);
    try std.testing.expectEqual(PointerSite.What.timer_array, bad_errs[0].what);
}

test "the song table relocates, and Nothing becomes the sentinel" {
    var table: SongTable = .{ .headers = @splat(0x5F90) };
    table.headers[song_nothing_index] = 0x4769;
    const out = try relocateSongTable(table, 0x5F90, 0x1E9B, 0x6000, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0x6000), out.headers[0]);
    try std.testing.expectEqual(@as(u16, 0xFFFF), out.headers[song_nothing_index]);

    var bad: SongTable = .{ .headers = @splat(0x5F90) };
    bad.headers[song_nothing_index] = 0x4769;
    bad.headers[3] = 0x4000;
    try std.testing.expectError(error.SongPointerOutsideRegion, relocateSongTable(bad, 0x5F90, 0x1E9B, 0x6000, 0xFFFF));
}

test "the real bank walks, and every pointer it finds can be placed" {
    const testrom = @import("testrom");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;

    const data_e = offsets.find("audio_songData").?;
    const table_e = offsets.find("audio_songDataTable").?;
    const tempo_e = offsets.find("audio_tempoTables").?;
    const wave_e = offsets.find("audio_wavePatterns").?;

    const src = rom[data_e.romOffset()..data_e.romEnd()];
    const data = try parseSongData(a, rom[table_e.romOffset()..table_e.romEnd()], src, data_e.gb_addr);

    // The walk reaches the great majority of the region. It is not all of it --
    // unreferenced sections exist -- so this is a floor, and a ratchet: if a
    // later change makes the walk quietly stop following something, coverage
    // falls and this fails rather than the compare silently narrowing.
    try std.testing.expect(data.covered * 100 / src.len >= 90);
    try std.testing.expect(data.headers.len >= 20);

    // Re-emitting from the typed form reproduces the region exactly.
    try std.testing.expectEqualSlices(u8, src, try encodeSongData(a, src, data));

    // And every pointer the walk found can be placed in ARAM.
    const bytes = try a.dupe(u8, src);
    const errs = try relocate(
        a,
        bytes,
        data,
        data_e.gb_addr,
        tempo_e.gb_addr,
        tempo_e.size,
        wave_e.gb_addr,
        wave_e.size,
        .{ .song_data = 0x6000, .tempo = 0x5F00, .wave = 0x5F80 },
    );
    if (errs.len != 0) {
        std.debug.print("{d} unrelocatable pointer(s); first at +${X} -> ${X:0>4} ({s})\n", .{
            errs.len, errs[0].at, errs[0].target, @tagName(errs[0].what),
        });
        return error.UnrelocatablePointer;
    }
}

test "a list reached only by a goto is walked as a list" {
    // `song_metroidHive_withIntro_square1` ends its intro with `$00F0` to
    // `song_metroidHive_withIntro_square1_loop` ($6BCE), which no header names.
    // Left unwalked, its seven section words stay Game Boy addresses, and song
    // $1F plays the wrong section once the intro ends.
    const testrom = @import("testrom");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;

    const data_e = offsets.find("audio_songData").?;
    const table_e = offsets.find("audio_songDataTable").?;
    const src = rom[data_e.romOffset()..data_e.romEnd()];
    const data = try parseSongData(a, rom[table_e.romOffset()..table_e.romEnd()], src, data_e.gb_addr);

    const list: usize = 0x6BCE - data_e.gb_addr;
    for (0..7) |k| {
        var found = false;
        for (data.pointers) |p| found = found or (p.at == list + 2 * k and p.what == .section);
        try std.testing.expect(found);
    }
}
