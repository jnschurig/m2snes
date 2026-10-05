//! Where everything sits in the SPC700's 64 KiB of ARAM (metroid2-audio Step 5).
//!
//! The cart uploads one image at boot and never touches ARAM again, so this is
//! the single statement of what that image contains: the GB APU shim, the
//! ported sound engine, bank 4's data, the wave lookup and the samples. It is
//! the ARAM counterpart of `snes_layout.zig`, which does the same job for the
//! cartridge's own address space.
//!
//! **The shim owns the map, and this module obeys it.** `audio/shim/shimpkg.zig`
//! is generated from the shim's own `memmap.inc`, so the region bounds here are
//! not a second opinion — they are read from the package, and `check` asserts
//! that every segment lands inside the region the shim says it should and that
//! no two segments overlap. A layout that drifted from the shim's would place
//! the engine's data somewhere the engine would not look for it, and on the
//! SPC700 that is silent.
//!
//! ## Why the data has to be placed before the pointers can be written
//!
//! Bank 4's song data is full of pointers to itself, and to the tempo tables
//! and wave patterns outside it. On the Game Boy those are $4000–$7FFF bank
//! addresses. Here they are ARAM addresses, so the builder has to know where
//! each region landed before it can rewrite a single pointer — which is why
//! placement is a separate pass, and why `audio_data.relocate` takes a
//! `Placement` rather than computing one.

const std = @import("std");
const offsets = @import("offsets.zig");
const audio_data = @import("audio_data.zig");
const shimpkg = @import("shimpkg");

/// The regions of ARAM, as the shim's memory map names them. A segment belongs
/// to exactly one, and `check` is what enforces that.
pub const Class = enum {
    /// All of ARAM below the engine's RAM: the shim's code, its configuration
    /// block, the square BRR bank, the DSP directory and the pitch table.
    ///
    /// One class rather than five, because how the shim subdivides its own low
    /// memory is the shim's business and `shimpkg.segments` already states it.
    /// This module places what that function returns, at the addresses it
    /// returns, and checks only that the lot stays below the engine's RAM.
    shim,
    /// The ported sound engine's own RAM, including the reply the 65816 reads.
    engine_ram,
    /// The ported sound engine's code.
    engine_code,
    /// Bank 4's data, extracted and relocated. This is what this module places.
    sound_data,
    /// The wave lookup table the shim consults on a CH3 trigger.
    wave_lut,
    /// BRR samples.
    samples,

    pub fn bounds(self: Class) struct { start: u16, end: u16 } {
        return switch (self) {
            .shim => .{ .start = shimpkg.shim_code_addr, .end = shimpkg.engine_ram_addr },
            .engine_ram => .{ .start = shimpkg.engine_ram_addr, .end = shimpkg.engine_ram_end },
            .engine_code => .{ .start = shimpkg.engine_code_addr, .end = shimpkg.engine_code_end },
            .sound_data => .{ .start = shimpkg.engine_data_addr, .end = shimpkg.engine_data_end },
            .wave_lut => .{ .start = shimpkg.wave_lut_addr, .end = shimpkg.wave_lut_end },
            .samples => .{ .start = shimpkg.samples_addr, .end = shimpkg.samples_end },
        };
    }

    pub fn capacity(self: Class) usize {
        const b = self.bounds();
        return b.end - b.start;
    }
};

pub const Segment = struct {
    name: []const u8,
    class: Class,
    addr: u16,
    size: usize,

    pub fn end(self: Segment) usize {
        return @as(usize, self.addr) + self.size;
    }
};

/// The bank-4 entries that go into ARAM, in the order they are placed.
///
/// Order is by name rather than by Game Boy address, and deliberately so: the
/// ARAM image should not inherit the cartridge's layout, because a reader who
/// saw the two agree would reasonably assume one was derived from the other.
/// The three regions that pointers address — the song data, the tempo tables
/// and the wave patterns — are placed first so their addresses are the ones a
/// reader checks.
pub const data_entries = [_][]const u8{
    "audio_songData",
    "audio_tempoTables",
    "audio_wavePatterns",
    "audio_songDataTable",
    "audio_songStereoFlags",
    "audio_musicNotes",
    "audio_songNoiseOptionSets",
    "audio_songEffectTables",
    "audio_pausedOptionSets",
    "audio_optionSets_square1",
    "audio_optionSets_square2",
    "audio_optionSets_wave",
    "audio_optionSets_noise",
    "audio_stateSizes",
};

/// Bytes past an entry's end that the engine reads, because the Game Boy's
/// code indexes the entry with no bound and the song data reaches past it.
/// Each is placed straight after its entry and holds the ROM's bytes from
/// there, so the overread gets what the Game Boy gets. They are not a second
/// copy of anything the engine addresses by name.
pub const Overread = struct { entry: []const u8, bytes: usize };

pub const overreads = [_]Overread{
    // `loadNextSound` indexes `musicNotes` by the note byte plus `songTranspose`,
    // eight bits, and reads two bytes: offsets up to $100. A length byte followed
    // by `$F4` makes the `$F4` a note (subCaves3, finalCaves, the hive with its
    // intro), which on the Game Boy reads the tempo tables as a frequency.
    .{ .entry = "audio_musicNotes", .bytes = 0x101 - 0x92 },
    // The effect timer counts $10 down to $00 and is shared, so index $10 reads
    // the next table's first byte, and on table $A the byte after the last
    // table: `handleAudio`'s first opcode, $FA. finalCaves' square 2 bends by it.
    .{ .entry = "audio_songEffectTables", .bytes = 1 },
    // A note byte >= $9F indexes the tempo table `$F2` chose by its low bits
    // with bits 7 and 5 cleared: up to $5F past the last table's start ($68),
    // $48 bytes past the region's end. `rom0000` starts with one, `$C3`.
    .{ .entry = "audio_tempoTables", .bytes = 0x68 + 0x5F + 1 - 0x75 },
};

/// The first bytes of the Game Boy's address space, which the engine reads in
/// two places where a pointer is still the `$0000` `initializeAudio` left.
///
/// - As song data, when `$F5` repeats to a repeat point no `$F4` ever set.
///   subCaves3 without its intro does this on its wave channel, because its
///   first `$F4` is eaten as a note (see `overreads`). From `$0000` the Game
///   Boy reads `C3 FB 01 00`: a length, a note, a rest and the end of the
///   list, which moves the channel to its next section, so four bytes.
/// - As a wave pattern, sixteen bytes, when `$FF` stops the low-health beep
///   and no song has set one: at boot, or under a song whose wave channel
///   never runs `$F1`, like the earthquake.
///
/// The engine redirects a `$0000` pointer here in both places.
pub const rom0000_name = "rom0000";
pub const rom0000_size: usize = 16;

/// How far past its entry the engine reads (see `overreads`).
pub fn overread(name: []const u8) usize {
    for (overreads) |o| {
        if (std.mem.eql(u8, o.entry, name)) return o.bytes;
    }
    return 0;
}

/// CH3's waves: `wavePatterns.wave0` through `.wave6`, as offsets into
/// `audio_wavePatterns` (bank 4's symbols, `vendor/m2ros/bank4.sym`). The 56
/// bytes between wave1 and wave2 are no wave, and the shim's lookup holds these
/// seven only. A test holds every `$F1` in the song data to this list; wave5
/// is the one no song names, so it is reached from code (a sound effect) and
/// rests on the symbol file alone.
pub const wave_offsets = [_]u8{ 0x00, 0x10, 0x58, 0x68, 0x78, 0x88, 0x98 };

/// The wave lookup: a count, then each wave's sixteen bytes.
pub const wave_lut_size: usize = 1 + wave_offsets.len * shimpkg.wave.entry_size;
/// The waves' BRR, from the bottom of the samples region, and CH4's seven-bit
/// noise samples straight after, as the package asks.
pub const wave_samples_addr: u16 = shimpkg.samples_addr;
pub const wave_samples_size: usize = wave_offsets.len * shimpkg.wave.bytes_per_wave;
pub const noise_samples_addr: u16 = wave_samples_addr + wave_samples_size;

/// The DSP directory: the square bank, a slot for each of the lookup's
/// `Wave.lut_max` waves (the seven used, the rest empty), then the noise tiers
/// at `Noise.srcn_base`. Addresses only, so it needs no ROM.
pub const dsp_directory = blk: {
    const n_extra = shimpkg.Noise.srcn_base + shimpkg.Noise.samples - shimpkg.square_count;
    var extra: [n_extra]shimpkg.SampleEntry = @splat(.{ .start = 0, .loop = 0 });
    for (0..wave_offsets.len) |i| for (0..shimpkg.Wave.samples_per) |li| {
        const a = shimpkg.wave.sampleAddr(wave_samples_addr, i, li);
        extra[shimpkg.Wave.srcn_base - shimpkg.square_count + i * shimpkg.Wave.samples_per + li] = .{ .start = a, .loop = a };
    };
    for (0..shimpkg.Noise.samples) |t| {
        const a = shimpkg.noise.sampleAddr(noise_samples_addr, t);
        extra[shimpkg.Noise.srcn_base - shimpkg.square_count + t] = .{ .start = a, .loop = a };
    }
    var out: [(shimpkg.square_count + n_extra) * 4]u8 = undefined;
    _ = shimpkg.directory(&out, &extra) catch unreachable;
    break :blk out;
};

pub const Layout = struct {
    segments: []Segment,

    /// Where a named segment landed, or null if it is not in this layout.
    pub fn find(self: Layout, name: []const u8) ?Segment {
        for (self.segments) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn used(self: Layout, class: Class) usize {
        var n: usize = 0;
        for (self.segments) |s| {
            if (s.class == class) n += s.size;
        }
        return n;
    }

    /// The three regions the song data's pointers address, as
    /// `audio_data.relocate` wants them.
    pub fn placement(self: Layout) audio_data.Placement {
        return .{
            .song_data = self.find("audio_songData").?.addr,
            .tempo = self.find("audio_tempoTables").?.addr,
            .wave = self.find("audio_wavePatterns").?.addr,
        };
    }
};

pub const Overflow = struct {
    class: Class,
    used: usize,
    capacity: usize,
};

/// Place the shim's segments, the engine image and bank 4's data.
///
/// `engine_code_size` is the assembled `engine/audio.bin`'s length. Returns an
/// error naming the region that did not fit rather than producing a layout that
/// overlaps, because a builder that silently overran would write an engine's
/// data over its code.
pub fn plan(arena: std.mem.Allocator, engine_code_size: usize) !Layout {
    var segs: std.ArrayList(Segment) = .empty;

    // The shim's own regions come from the package, not from a copy of it.
    const shim_segments = shimpkg.segments(&shimpkg.config_hosted, &dsp_directory);
    for (shim_segments, 0..) |s, i| {
        var buf: [32]u8 = undefined;
        const name = try arena.dupe(u8, try std.fmt.bufPrint(&buf, "shim[{d}]", .{i}));
        try segs.append(arena, .{
            .name = name,
            .class = .shim,
            .addr = s.addr,
            .size = s.bytes.len,
        });
    }

    try segs.append(arena, .{
        .name = "engine/audio.bin",
        .class = .engine_code,
        .addr = shimpkg.engine_code_addr,
        .size = engine_code_size,
    });
    try segs.append(arena, .{
        .name = "engine reply",
        .class = .engine_ram,
        .addr = shimpkg.engine_reply_addr,
        .size = shimpkg.engine_reply_size,
    });

    try segs.append(arena, .{ .name = "wave lookup", .class = .wave_lut, .addr = shimpkg.wave_lut_addr, .size = wave_lut_size });
    try segs.append(arena, .{ .name = "wave samples", .class = .samples, .addr = wave_samples_addr, .size = wave_samples_size });
    try segs.append(arena, .{ .name = "noise samples", .class = .samples, .addr = noise_samples_addr, .size = shimpkg.noise.bytes });

    var at: usize = shimpkg.engine_data_addr;
    for (data_entries) |name| {
        const e = offsets.find(name) orelse return error.UnknownAudioEntry;
        try segs.append(arena, .{
            .name = e.name,
            .class = .sound_data,
            .addr = @intCast(at),
            .size = e.size + overread(name),
        });
        at += e.size + overread(name);
    }
    try segs.append(arena, .{ .name = rom0000_name, .class = .sound_data, .addr = @intCast(at), .size = rom0000_size });

    return .{ .segments = try segs.toOwnedSlice(arena) };
}

/// Every segment inside the region its class claims, and no two overlapping.
///
/// Returns the first region that overflows, or null. Overlap is an assertion
/// rather than a returned error: two segments in the same class can only
/// overlap if `plan` has a bug, and a builder should not carry on past that.
pub fn check(layout: Layout) ?Overflow {
    for (layout.segments) |s| {
        const b = s.class.bounds();
        std.debug.assert(s.addr >= b.start);
        if (s.end() > b.end) {
            return .{ .class = s.class, .used = layout.used(s.class), .capacity = s.class.capacity() };
        }
    }
    for (layout.segments, 0..) |a, i| {
        for (layout.segments[i + 1 ..]) |b| {
            std.debug.assert(a.end() <= b.addr or b.end() <= a.addr);
        }
    }
    return null;
}

/// Print the ARAM layout by region, the way `snes_layout.print` does for the
/// cart. `zig build convert` ends with this.
pub fn print(layout: Layout, out: anytype) !void {
    try out.print("\nARAM ({d} KiB, uploaded once at boot; regions from audio/shim/shimpkg.zig)\n\n", .{64});
    try out.print("  {s:<14} {s:>7} {s:>8} {s:>9} {s:>9}\n", .{ "region", "start", "used", "reserved", "headroom" });
    inline for (@typeInfo(Class).@"enum".fields) |f| {
        const class: Class = @field(Class, f.name);
        const b = class.bounds();
        const used = layout.used(class);
        try out.print("  {s:<14}  ${X:0>4} {d:>8} {d:>9} {d:>8}%\n", .{
            f.name, b.start, used, class.capacity(),
            if (class.capacity() == 0) 0 else (class.capacity() - used) * 100 / class.capacity(),
        });
    }
    try out.print("\n  bank 4's data, placed:\n", .{});
    for (layout.segments) |s| {
        if (s.class != .sound_data) continue;
        try out.print("    {s:<28} ${X:0>4}  {d:>5} bytes\n", .{ s.name, s.addr, s.size });
    }
}

/// The engine's view of this layout, as assembly the SPC700 engine includes.
///
/// The engine addresses bank 4's data by absolute ARAM address, and those
/// addresses are this module's to decide. Writing them by hand in the assembly
/// would be a second opinion that could quietly drift from `plan`, and on the
/// SPC700 reading the wrong table is silent, so the assembly reads them from
/// here instead — the same bargain `audio/shim/shim_abi.inc` makes for the
/// shim's own map.
///
/// The names are the segment names with their `audio_` prefix dropped and a
/// `DATA__` prefix added, which is the shape the assembly's other includes use.
pub fn includeText(allocator: std.mem.Allocator) ![]u8 {
    const layout = try plan(allocator, 0);
    if (check(layout)) |o| {
        std.debug.print("ARAM region {s} overflows: {d} of {d}\n", .{ @tagName(o.class), o.used, o.capacity });
        return error.AramOverflow;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator,
        \\; Where bank 4's data sits in ARAM, for the sound engine's assembly.
        \\;
        \\; GENERATED by `zig build aramsyms` from `src/aram_layout.zig`. Do not
        \\; edit: regenerate it there. `zig build verify` fails when the committed
        \\; file stops matching what the layout plans.
        \\
        \\
    );
    var end: usize = shimpkg.engine_data_addr;
    for (layout.segments) |s| {
        if (s.class != .sound_data) continue;
        const name = if (std.mem.startsWith(u8, s.name, "audio_")) s.name["audio_".len..] else s.name;
        try buf.print(allocator, "    DATA__{s} = ${X:0>4}\n", .{ name, s.addr });
        if (s.end() > end) end = s.end();
    }
    // The end of the last segment, so the assembly can assert that every
    // address it derives lands inside the data it was actually given.
    try buf.print(allocator, "    DATA__END = ${X:0>4}\n", .{end});
    return buf.toOwnedSlice(allocator);
}

/// The committed copy's path. Named here so the generator and the check that
/// it is current cannot disagree about which file they mean.
pub const include_path = "engine/audio/aram_data.inc";

// ---- Tests -----------------------------------------------------------------

test "the layout fits, obeys the shim's regions, and overlaps nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const layout = try plan(arena.allocator(), 4096);
    try std.testing.expectEqual(@as(?Overflow, null), check(layout));
    try std.testing.expect(layout.used(.sound_data) > 9000);
    try std.testing.expect(layout.used(.sound_data) < Class.sound_data.capacity());
}

test "every bank-4 sound entry is placed exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const layout = try plan(arena.allocator(), 4096);
    var placed: usize = 0;
    for (offsets.entries) |e| {
        const is_sound = switch (e.kind) {
            .sound_notes, .sound_tempo, .sound_wave_patterns, .sound_option_sets,
            .sound_effect_table, .sound_song_table, .sound_flags, .sound_song_data => true,
            // The three `jp` trampolines are the Game Boy engine's entry points.
            // The engine is being rewritten, so they are not carried to ARAM.
            .sound_entry => false,
            else => false,
        };
        if (!is_sound) continue;
        placed += 1;
        const s = layout.find(e.name) orelse {
            std.debug.print("{s} is an ARAM-bound sound entry but nothing placed it\n", .{e.name});
            return error.EntryNotPlaced;
        };
        try std.testing.expectEqual(e.size + overread(e.name), s.size);
    }
    try std.testing.expectEqual(data_entries.len, placed);
}

test "an engine that overruns its region is refused rather than laid out over the data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const layout = try plan(arena.allocator(), Class.engine_code.capacity() + 1);
    const over = check(layout) orelse return error.OverflowNotCaught;
    try std.testing.expectEqual(Class.engine_code, over.class);
}

test "the real song data relocates into the planned layout with nothing left over" {
    const testrom = @import("testrom");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;

    const layout = try plan(a, 4096);
    try std.testing.expectEqual(@as(?Overflow, null), check(layout));

    const data_e = offsets.find("audio_songData").?;
    const table_e = offsets.find("audio_songDataTable").?;
    const tempo_e = offsets.find("audio_tempoTables").?;
    const wave_e = offsets.find("audio_wavePatterns").?;

    const src = rom[data_e.romOffset()..data_e.romEnd()];
    const data = try audio_data.parseSongData(a, rom[table_e.romOffset()..table_e.romEnd()], src, data_e.gb_addr);
    const bytes = try a.dupe(u8, src);
    const errs = try audio_data.relocate(
        a, bytes, data,
        data_e.gb_addr,
        tempo_e.gb_addr, tempo_e.size,
        wave_e.gb_addr, wave_e.size,
        layout.placement(),
    );
    try std.testing.expectEqual(@as(usize, 0), errs.len);

    // Every relocated pointer now addresses ARAM, inside the region its kind
    // belongs to. Checked here rather than trusted from `relocate`'s return:
    // the point of the pass is where the bytes end up, not that it ran.
    const song = layout.find("audio_songData").?;
    const tempo = layout.find("audio_tempoTables").?;
    const wave = layout.find("audio_wavePatterns").?;
    for (data.pointers) |p| {
        const v = @as(u16, bytes[p.at]) | (@as(u16, bytes[p.at + 1]) << 8);
        const s = switch (p.what) {
            .timer_array => tempo,
            .wave_pattern => wave,
            else => song,
        };
        if (v < s.addr or v >= s.end()) {
            std.debug.print("pointer +${X} ({s}) relocated to ${X:0>4}, outside {s} ${X:0>4}-${X:0>4}\n", .{
                p.at, @tagName(p.what), v, s.name, s.addr, s.end(),
            });
            return error.RelocatedOutsideRegion;
        }
    }

    // Every wave the song data names is one the shim's lookup holds: a `$F1`
    // pointing anywhere else would reach wave RAM as contents the lookup
    // misses, and CH3 would play silence. Read from the ROM, before relocation.
    var waves_named: usize = 0;
    for (data.pointers) |p| {
        if (p.what != .wave_pattern) continue;
        const gb = @as(u16, src[p.at]) | (@as(u16, src[p.at + 1]) << 8);
        const off = gb - wave_e.gb_addr;
        if (std.mem.indexOfScalar(u8, &wave_offsets, @intCast(off)) == null) {
            std.debug.print("song data +${X} names wave +${X}, not in wave_offsets\n", .{ p.at, off });
            return error.UnknownWave;
        }
        waves_named += 1;
    }
    try std.testing.expect(waves_named > 0);

    // And the song table, whose one code pointer becomes the sentinel.
    const table = try audio_data.SongTable.decode(rom[table_e.romOffset()..table_e.romEnd()]);
    const moved = try audio_data.relocateSongTable(table, data_e.gb_addr, data_e.size, song.addr, 0);
    for (moved.headers, 0..) |h, i| {
        if (i == audio_data.song_nothing_index) {
            try std.testing.expectEqual(@as(u16, 0), h);
        } else {
            try std.testing.expect(h >= song.addr and h < song.end());
        }
    }
}

test "every overread names a placed entry" {
    for (overreads) |o| {
        var found = false;
        for (data_entries) |name| found = found or std.mem.eql(u8, name, o.entry);
        try std.testing.expect(found);
        try std.testing.expect(o.bytes > 0);
    }
}
