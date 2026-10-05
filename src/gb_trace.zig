//! The reference *trace*: what the original machine did, frame by frame, over
//! a run recorded on it.
//!
//! `tas.zig` grades a published movie by replaying it on our own Game Boy
//! emulator, and that is the right shape when the movie is a `.vbm` and the
//! replay holds. It does not hold here. James's B11 recording is a Mesen2
//! `.mmo`, and converted to a VBM our emulator stops being his run at 28 796 of
//! 76 950 frames — `zig build tas -- rec` still measures that and is kept as a
//! probe. So the reference for Phase 0b is not a replay we perform; it is a
//! **trace taken from the emulator that recorded it**, and this file takes it.
//!
//! Everything below was measured against Mesen2 2.2.1 on 2026-09-08 rather than
//! assumed, because almost none of it is documented.
//!
//! **Mesen cannot be asked to play its own movie headlessly.** `--testrunner`
//! takes exactly one file, and there is no `emu.playMovie`/`loadMovie`/
//! `startMovie`/`loadRom` in the Lua surface. So the script re-drives the
//! movie's inputs itself, from `Input.txt`, onto the machine state in
//! `SaveState.mss` — which `emu.loadSavestate` will only accept from inside an
//! `addMemoryCallback(.exec)` on the main CPU, another measured contract.
//!
//! **The input index is `IN[f]`, not `IN[f+1]`.** Reading a frame ahead cost
//! this step a day: it desynced the recording at 2 301 frames and was mistaken
//! for the recording losing the run. The explanation offered at the time — that
//! `emu.setInput` from `inputPolled` lands after the frame's latch and so
//! arrives a frame late — is **wrong, and this file measures it wrong**:
//! `Pass.lag` reads zero. Mesen's `inputPolled` fires once a frame whether the
//! game asks or not, ahead of the frame it belongs to, so what the script sets
//! during frame f is what the game reads during frame f. `IN[f+1]` was simply
//! one frame ahead of the movie.
//!
//! Which is why nothing here trusts the constant. Every pass records `$FF80`,
//! the byte the game's own joypad routine leaves for the pose machine, beside
//! the number of times the game read `$FF00`; `Pass.lag` finds the shift that
//! explains them and a pass with no such shift is rejected as a desync rather
//! than written out.
//!
//! **The channel out is cart RAM, and it was widened.** `emu.log` is swallowed
//! and lua's `io` is nil on the Game Boy side too, exactly as on the SNES side,
//! so the only wide channel is the same one `snes_trace.zig` uses: save RAM,
//! which Mesen writes to a `.srm` on power-off. Metroid II's header declares
//! 8 KiB, which is 512 frames of this record. Re-stamping the RAM-size byte of
//! a *copy* of the ROM to `$03` gives MBC1's full 32 KiB, Mesen writes all of
//! it, `emu.write(..., gbCartRam)` addresses it linearly across all four banks,
//! and a savestate recorded on the unstamped ROM loads into it without
//! complaint. All four of those were probed, and the fourth is the one that
//! could have gone the other way.
//!
//! The stamped copy is also why the sampler does not have to touch the user's
//! own save: it runs `m2trace.gb`, so Mesen writes `m2trace.srm` and
//! `metroid2.srm` — a real Metroid II save game — is never opened.
//!
//! One run is one **pass**: a window of at most `max_frames` frames recorded
//! out of a movie of any length. A trace longer than that is several passes,
//! each replaying the movie from its savestate and recording a different
//! window. Headless runs at roughly 700 frames a second, so a pass costs about
//! as long as the movie is; this is a vendoring job, not a gate.

const std = @import("std");
const tas = @import("tas.zig");

pub const Error = error{
    NotAZip,
    NoSuchEntry,
    BadInputRow,
    NoInputRows,
    NoSaveFolder,
    NoSaveFile,
    ShortSaveFile,
    DidNotRun,
    WrongCartridge,
    TooManyFrames,
    BadStretch,
    InputMisaligned,
    OutOfMemory,
};

// ---- The recording --------------------------------------------------------

/// A Mesen2 movie: a zip holding `Input.txt`, `GameSettings.txt` and
/// `SaveState.mss`.
pub const Recording = struct {
    /// One byte per frame, in `tas.held_*` order — which is the Game Boy's own
    /// button order, so this column is directly comparable with the published
    /// runs' `Sample.input`.
    inputs: []const u8,
    /// `SaveState.mss`, handed to `emu.loadSavestate` verbatim. Mesen records
    /// one at the head of every movie, so a recording always starts from a
    /// state rather than from power-on.
    state: []const u8,
    /// `GameSettings.txt`, kept whole: it carries the cartridge the recording
    /// was made on, which `checkCartridge` refuses to skip.
    settings: []const u8,

    pub fn deinit(self: *Recording, allocator: std.mem.Allocator) void {
        allocator.free(self.inputs);
        allocator.free(self.state);
        allocator.free(self.settings);
        self.* = undefined;
    }

    pub fn frames(self: Recording) usize {
        return self.inputs.len;
    }

    /// The ROM file name the recording names, or null if the settings do not.
    pub fn gameFile(self: Recording) ?[]const u8 {
        return settingValue(self.settings, "GameFile");
    }

    /// The SHA-1 the recording names, uppercase hex, or null.
    pub fn sha1(self: Recording) ?[]const u8 {
        return settingValue(self.settings, "SHA1");
    }

    /// Refuse a recording made on another cartridge.
    ///
    /// `tas.parse` already refuses a `.vbm` recorded elsewhere, by title and
    /// the two header checksums, because that is what a VBM carries. A `.mmo`
    /// carries the whole SHA-1, so this is the stronger check of the two and
    /// there is no reason to weaken it to match.
    pub fn checkCartridge(self: Recording, rom: []const u8) Error!void {
        const want = self.sha1() orelse return Error.WrongCartridge;
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        std.crypto.hash.Sha1.hash(rom, &digest, .{});
        var hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{X}", .{&digest}) catch unreachable;
        if (want.len != hex.len) return Error.WrongCartridge;
        for (want, hex) |a, b| {
            if (std.ascii.toUpper(a) != b) return Error.WrongCartridge;
        }
    }
};

fn settingValue(settings: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != ' ') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], " \r\t");
    }
    return null;
}

/// `Input.txt`'s column order, left to right: `|..|UDLRSsBA`.
///
/// The bit each column sets is `tas.held_*`, so a row parses into exactly the
/// byte the VBM path already produces for the same buttons.
const columns = [8]struct { ch: u8, bit: u8 }{
    .{ .ch = 'U', .bit = tas.held_up },
    .{ .ch = 'D', .bit = tas.held_down },
    .{ .ch = 'L', .bit = tas.held_left },
    .{ .ch = 'R', .bit = tas.held_right },
    .{ .ch = 'S', .bit = tas.held_start },
    .{ .ch = 's', .bit = tas.held_select },
    .{ .ch = 'B', .bit = tas.held_b },
    .{ .ch = 'A', .bit = tas.held_a },
};

/// Where the first controller's eight columns start in a row.
const row_prefix = "|..|";

pub fn parseInputs(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, row_prefix)) return Error.BadInputRow;
        const cols = line[row_prefix.len..];
        if (cols.len < columns.len) return Error.BadInputRow;
        var held: u8 = 0;
        for (columns, 0..) |c, i| {
            if (cols[i] == c.ch) {
                held |= c.bit;
            } else if (cols[i] != '.') {
                return Error.BadInputRow;
            }
        }
        try out.append(allocator, held);
    }
    if (out.items.len == 0) return Error.NoInputRows;
    return out.toOwnedSlice(allocator);
}

pub fn readRecording(allocator: std.mem.Allocator, mmo: []const u8) Error!Recording {
    const text = try zipEntry(allocator, mmo, "Input.txt");
    defer allocator.free(text);
    const inputs = try parseInputs(allocator, text);
    errdefer allocator.free(inputs);
    const state = try zipEntry(allocator, mmo, "SaveState.mss");
    errdefer allocator.free(state);
    const settings = try zipEntry(allocator, mmo, "GameSettings.txt");
    return .{ .inputs = inputs, .state = state, .settings = settings };
}

// ---- Just enough zip ------------------------------------------------------
//
// `std.zip` extracts to a directory from a `File.Reader`; these three files are
// wanted in memory and are small, so the central directory is walked here
// instead. Deflate itself is `std.compress.flate`.

fn zipEntry(allocator: std.mem.Allocator, zip: []const u8, name: []const u8) Error![]u8 {
    if (zip.len < 22) return Error.NotAZip;
    // The end-of-central-directory record, found by scanning back over the
    // comment field it is allowed to carry.
    var eocd: usize = zip.len - 22;
    while (true) : (eocd -= 1) {
        if (std.mem.eql(u8, zip[eocd..][0..4], &std.zip.end_record_sig)) break;
        if (eocd == 0) return Error.NotAZip;
    }
    const count = std.mem.readInt(u16, zip[eocd + 10 ..][0..2], .little);
    var at: usize = std.mem.readInt(u32, zip[eocd + 16 ..][0..4], .little);

    for (0..count) |_| {
        if (at + 46 > zip.len) return Error.NotAZip;
        if (!std.mem.eql(u8, zip[at..][0..4], &std.zip.central_file_header_sig)) return Error.NotAZip;
        const method = std.mem.readInt(u16, zip[at + 10 ..][0..2], .little);
        const csize: usize = std.mem.readInt(u32, zip[at + 20 ..][0..4], .little);
        const usize_: usize = std.mem.readInt(u32, zip[at + 24 ..][0..4], .little);
        const name_len: usize = std.mem.readInt(u16, zip[at + 28 ..][0..2], .little);
        const extra_len: usize = std.mem.readInt(u16, zip[at + 30 ..][0..2], .little);
        const comment_len: usize = std.mem.readInt(u16, zip[at + 32 ..][0..2], .little);
        const local: usize = std.mem.readInt(u32, zip[at + 42 ..][0..4], .little);
        const this_name = zip[at + 46 ..][0..name_len];
        at += 46 + name_len + extra_len + comment_len;
        if (!std.mem.eql(u8, this_name, name)) continue;

        // The local header repeats the name and carries its own extra field,
        // whose length differs from the central one often enough that reading
        // it from there is a real bug rather than a theoretical one.
        if (local + 30 > zip.len) return Error.NotAZip;
        if (!std.mem.eql(u8, zip[local..][0..4], &std.zip.local_file_header_sig)) return Error.NotAZip;
        const l_name: usize = std.mem.readInt(u16, zip[local + 26 ..][0..2], .little);
        const l_extra: usize = std.mem.readInt(u16, zip[local + 28 ..][0..2], .little);
        const start = local + 30 + l_name + l_extra;
        if (start + csize > zip.len) return Error.NotAZip;
        const data = zip[start..][0..csize];

        if (method == 0) return allocator.dupe(u8, data);
        var input: std.Io.Reader = .fixed(data);
        const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(window);
        var d = std.compress.flate.Decompress.init(&input, .raw, window);
        return d.reader.readAlloc(allocator, usize_) catch Error.NotAZip;
    }
    return Error.NoSuchEntry;
}

// ---- The cartridge's scratch buffer ---------------------------------------

/// `$149`, the RAM-size byte, set to four 8 KiB banks. MBC1's maximum, and the
/// largest widening available without also changing `$147` — which would swap
/// the memory-bank controller under a game that is mid-replay, and is not worth
/// four more banks.
pub const ram_size_byte: u8 = 0x03;
pub const sram_bytes: usize = 32 * 1024;

/// The header bytes the Game Boy's boot ROM checksums, `$134`..`$14C`, with the
/// result at `$14D`. Re-stamped rather than left stale: the boot ROM refuses to
/// start a cartridge whose header checksum does not match, so a copy with a
/// widened RAM-size byte and the original checksum would not boot at all.
const header_first: usize = 0x134;
const header_last: usize = 0x14C;
const header_checksum: usize = 0x14D;
pub const ram_size_addr: usize = 0x149;

/// The game's own save bank. Records start above it, so a pass can watch the
/// recording's saves land without the two overwriting each other.
pub const game_sram_bytes: usize = 8 * 1024;

/// Stamp a *copy* of the Game Boy ROM so Mesen gives it 32 KiB of battery RAM.
pub fn stampRam(rom: []u8) void {
    rom[ram_size_addr] = ram_size_byte;
    var sum: u8 = 0;
    for (rom[header_first .. header_last + 1]) |b| sum = sum -% b -% 1;
    rom[header_checksum] = sum;
}

/// Where the stamped copy and its script are written. `build-out/` is ignored
/// by git and skipped by `policy.zig`, which matters: the stamped copy is the
/// user's ROM with two bytes changed.
/// Where the recording is vendored. Not tracked and not downloadable: it is
/// James's own run, and `tools/get-tas.sh` says so rather than trying to fetch
/// it. Named here so the tools that read it agree on one path.
pub const recording_path = "reference/metroid2.mmo";

pub const out_dir = "build-out";
pub const stem = "m2trace";
pub const cart_name = out_dir ++ "/" ++ stem ++ ".gb";
pub const lua_name = out_dir ++ "/" ++ stem ++ ".lua";

// ---- The record -----------------------------------------------------------

/// One frame, as it is written into cart RAM.
///
/// The columns are `tas.Sample`'s, so a Mesen track and a replayed track are
/// the same table and the trace readers do not have to know which is which.
/// `frame` is not among them: a pass records a contiguous window and the
/// header says where it starts.
///
/// The last byte is not a `Sample` column. `pad` is `$FF80`, what the game's
/// own joypad routine left for the pose machine, and it is here so the input
/// alignment is checked against the game on every pass rather than trusted from
/// a comment — see `tas.pad_addr` and `Pass.lag`.
///
/// The game's own read count would say outright whether `$FF80` is this
/// frame's answer or last frame's, and it was tried: a `.read` callback on
/// `$FF00` instruments every memory read and took par01's first 1 361 frames
/// from two seconds to sixty-six. `Pass.lag` gets the same answer for free
/// instead — see the predicate there.
pub const Field = struct {
    name: []const u8,
    addr: u16,
    width: u3,
    /// How the script produces the column, because three of them are not
    /// reads. `mem` is a little-endian read of `width` bytes at `addr`;
    /// `input` is the byte the script itself handed the emulator, `digest` is
    /// the hash it computes, and the two block columns are counted by the
    /// script -- `live_blocks` per recorded frame, `blocks_seen` accumulated on
    /// every frame whether it is recorded or not. This tag is what lets `writeLua` emit the row
    /// *from this table* rather than beside it -- the two were written out
    /// twice, which is one place for a new column to be declared and not
    /// recorded.
    kind: Kind = .mem,

    pub const Kind = enum { mem, input, digest, live_blocks, blocks_seen };
};

pub const fields = [_]Field{
    .{ .name = "input", .addr = 0, .width = 1, .kind = .input },
    .{ .name = "samus_y", .addr = 0xFFC0, .width = 2 },
    .{ .name = "samus_x", .addr = 0xFFC2, .width = 2 },
    .{ .name = "camera_y", .addr = 0xFFC8, .width = 2 },
    .{ .name = "camera_x", .addr = 0xFFCA, .width = 2 },
    .{ .name = "pose", .addr = 0xD020, .width = 1 },
    .{ .name = "map_bank", .addr = 0xD811, .width = 1 },
    .{ .name = "metroid_count", .addr = 0xD089, .width = 1 },
    .{ .name = "wram_digest", .addr = 0, .width = 4, .kind = .digest },
    .{ .name = "pad", .addr = tas.pad_addr, .width = 1 },

    // ---- Not `tas.Sample` columns: the pickups, which B11 asks to be
    // located and which nothing on the SNES side has yet.
    //
    // `Pass.samples` ignores them, so a Mesen track still reads as the same
    // table every other track does; `zig build gbtrace -- ... items` is what
    // reads them back. The addresses are M2RoS's, from `SRC/ram/wram.asm`.

    // `$D045`, `samusItems`: the equipment bitfield. Bit 0 is the Bomb and
    // bit 5 the Spider Ball -- `SRC/constants.asm`'s `itemBit_bomb` and
    // `itemBit_spider`, mirrored in `item_bits` below.
    .{ .name = "items", .addr = 0xD045, .width = 1 },
    // `$D050`, `samusEnergyTanks`: max health in tanks, which is how an
    // Energy Tank pickup shows up.
    .{ .name = "etanks", .addr = 0xD050, .width = 1 },
    // `$D081`/`$D082`, `samusMaxMissiles`: max missiles, which is how a
    // Missile Tank shows up. The *max*, not the count: firing moves the count
    // and only a pickup moves the ceiling.
    .{ .name = "missiles_max", .addr = 0xD081, .width = 2 },

    // How many of `respawningBlockArray`'s sixteen slots hold a block the game
    // owes back, counted by the script.
    //
    // **This is the column that says whether an anchor needs a world.** A
    // stretch spawned where this is zero can be seeded from the pristine room
    // the cell describes; a stretch spawned where it is not cannot, and the
    // trace has to hand over the tilemap as well. Without it, "which anchors
    // need the expensive pass" is a guess.
    .{ .name = "live_blocks", .addr = blocks_addr, .width = 1, .kind = .live_blocks },
    // ---- The three `oracle.Frame` carries that `tas.Sample` does not.
    //
    // A stretch graded against this trace is graded through `oracle.Frame`,
    // and `Frame.eql` compares position, camera and pose -- which `tas.Sample`
    // already has. These three are the ones it *records and does not compare*,
    // and they are here for the reason they are there: when two machines
    // disagree about a step, no compared field can tell "the port acted a
    // frame early" from "the reference was handed the press a frame late", and
    // these three can.
    //
    // The addresses are `oracle.zig`'s own `gb_facing_addr`, `gb_counter_addr`
    // and `gb_water_addr`, duplicated rather than imported for the same
    // measured reason `savePath` is: that module pulls in the assembled
    // engine, which has nothing to do with the Game Boy side.

    // `samusFacingDirection`, read by `drawSamus_spinJump` (01:4CEE).
    .{ .name = "facing", .addr = 0xD02B, .width = 1 },
    // The counter `samus_walkRight` takes its 1/2 walk alternation from:
    // `LDH A,($97) / AND $01 / ADD A,$01` at 00:$1C25, so the speed on a frame
    // is `($FF97 & 1) + 1`. Our `WalkSpeed` derives the same number from
    // `!FrameCount`, which makes the two counters' *parity* part of the port.
    .{ .name = "counter", .addr = 0xFF97, .width = 1 },
    // `samusInWater`, which `samus_walkRight` reads at 00:$1C14 *before* it
    // consults the counter at all: nonzero and the walk speed is 1 every frame
    // instead of alternating. This is what tells a speed disagreement apart
    // from a contact disagreement.
    .{ .name = "water", .addr = 0xD048, .width = 1 },

    // Blocks destroyed since the pass began, counted on **every** frame.
    //
    // `live_blocks` alone cannot answer "does this run destroy blocks", because
    // `handleRespawningBlocks` (01:5692) drops a slot the moment the block
    // scrolls offscreen -- the array is current state, not history, and a
    // strided pass steps straight over the frames it is nonzero on. The
    // accumulator runs in the driver's own every-frame callback, so a stride-64
    // census still reports the true count.
    .{ .name = "blocks_seen", .addr = 0, .width = 2, .kind = .blocks_seen },
};

/// The two equipment bits Step 11 has to place, by name.
///
/// `samusItems` is eight flags and only these two are pickups the slice
/// reaches; the rest are named here so a census that trips one says which.
pub const item_bits = [8][]const u8{
    "bomb", "hi_jump", "screw", "space", "spring", "spider", "varia", "unused",
};

/// `samusBeam`'s values, from the comment on `$D055` in M2RoS's
/// `SRC/ram/wram.asm`.
pub const beam_names = [_][]const u8{ "power", "ice", "wave", "spazer", "plasma" };

pub fn beamName(v: u32) []const u8 {
    return if (v < beam_names.len) beam_names[v] else "?";
}

pub const record_bytes: usize = blk: {
    var n: usize = 0;
    for (fields) |f| n += f.width;
    break :blk n;
};

/// Cart-RAM offset of the pass header, and of the first record after it.
pub const header_at: usize = game_sram_bytes;
pub const header_bytes: usize = 64;
pub const records_at: usize = header_at + header_bytes;

pub const max_frames: usize = (sram_bytes - records_at) / record_bytes;

/// How many frames at each end of a row pass are digested whole, and where in
/// the header they go. Four and four fill the header's spare 36 bytes; a seam
/// is exact when any of one segment's last four matches any of the next one's
/// first four, which allows the two recordings to meet up to three frames apart.
pub const seam_frames: usize = 4;
pub const seam_at: usize = 28;

/// The beam and the clock on the pass's last frame, in the header's last four
/// bytes. Not columns: the record is the one graded stretches read too
/// (`Reference.pass`), and three more bytes a frame cost every stretch 85
/// frames. A beam pickup is placed to its segment by the end state, which is
/// what 1.0 Step 24a needed; a case that needs its frame takes a narrow pass.
///
/// `$D055` is `samusBeam`. `$D098`/`$D099` are `gameTimeMinutes` and
/// `gameTimeHours`, BCD, read as one word: the clock the ending is chosen on
/// (`cp $03`, `$05`, `$07` in bank 5).
pub const end_at: usize = seam_at + 2 * seam_frames * 4;
pub const beam_addr: u16 = 0xD055;
pub const clock_addr: u16 = 0xD098;
comptime {
    std.debug.assert(end_at + 3 <= header_bytes);
}

/// Every change of `samusBeam`, frame and value, logged in the last bytes of
/// cart RAM when the window leaves them free. The beam is not a column (see
/// `end_at`), and the end state alone cannot see a beam picked up and replaced
/// inside one segment -- the 100% run's spazer is exactly that.
///
/// A count byte, then entries of a 24-bit movie frame and the beam. A count
/// past `beam_log_entries` means changes were dropped, and says so.
pub const beam_log_entries: usize = 15;
pub const beam_log_bytes: usize = 1 + 4 * beam_log_entries;
/// Rows a window gives up so the log is always written: `run`'s caller asks
/// for at most `max_frames - beam_log_rows` to be sure of one.
pub const beam_log_rows: usize = (beam_log_bytes + record_bytes - 1) / record_bytes;

/// Where the log goes for a window of `count` rows, or 0 for none: it takes
/// the space after the rows, and only when the rows leave it.
pub fn beamLogAt(count: usize) usize {
    const at = sram_bytes - beam_log_bytes;
    return if (records_at + count * record_bytes <= at) at else 0;
}

pub const BeamChange = struct { frame: u32, beam: u8 };

/// What the script stamps at the head of its region, so a read-back can tell
/// "the run recorded a window" from "the run never got there".
pub const magic = [4]u8{ 'G', 'B', 'T', '1' };

// ---- The generated script -------------------------------------------------

/// Emit `bytes` as a Lua string literal, in pieces small enough not to lean on
/// the parser, concatenated with `table.concat`.
fn writeLuaBytes(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.print("table.concat{{\n", .{});
    var at: usize = 0;
    while (at < bytes.len) : (at += 1024) {
        const end = @min(at + 1024, bytes.len);
        try w.print("\"", .{});
        for (bytes[at..end]) |b| try w.print("\\{d}", .{b});
        try w.print("\",\n", .{});
    }
    try w.print("}}", .{});
}

/// The pass script: load the movie's savestate, re-drive its inputs, and record
/// `count` frames from `first` into cart RAM.
pub fn writeLua(
    w: *std.Io.Writer,
    rec: Recording,
    first: usize,
    count: usize,
    stride: usize,
    offset: usize,
) !void {
    if (count > max_frames) return Error.TooManyFrames;
    if (stride == 0) return Error.TooManyFrames;
    const last = @min(first + count * stride, rec.frames());

    try w.print(
        \\-- Generated by `zig build gbtrace`. Do not edit.
        \\--
        \\-- Replays a Mesen2 .mmo headlessly by re-driving its own Input.txt onto
        \\-- its own SaveState.mss, and records {d} bytes per frame into the cart's
        \\-- save RAM -- the only wide channel out of a testrunner run, since
        \\-- emu.log is swallowed and lua's io is nil. See src/gb_trace.zig.
        \\
        \\local STATE = 
    , .{record_bytes});
    try writeLuaBytes(w, rec.state);

    try w.print("\nlocal IN = ", .{});
    // Only the prefix the pass needs: the frames after its window are never
    // played, and a 76 951-frame movie is 300 KiB of escaped bytes.
    try writeLuaBytes(w, rec.inputs[0..last]);

    try w.print(
        \\
        \\
        \\local FIRST, COUNT, STRIDE = {d}, {d}, {d}
        \\local AT, REC = {d}, {d}
        \\local HDR = {d}
        \\
    , .{ first + offset, count, stride, header_at, record_bytes, header_bytes });

    try writeDriver(w, offset);

    try w.print(
        \\local SEAM, SEAM_AT, STOP = {d}, {d}, {d}
        \\local END_AT, BEAM, CLOCK = {d}, 0x{X:0>4}, 0x{X:0>4}
        \\local LOG, LOG_N = {d}, {d}
        \\local HEAD, TAIL = {{}}, {{}}
        \\local beamWas, nlog = nil, 0
        \\
    , .{ seam_frames, seam_at, last + offset, end_at, beam_addr, clock_addr, beamLogAt(count), beam_log_entries });

    try w.print(
        \\local function finish()
        \\  done = true
        \\  local at = AT
        \\  write(at + 0, 71, sram); write(at + 1, 66, sram)
        \\  write(at + 2, 84, sram); write(at + 3, 49, sram)
        \\  put(at + 4, FIRST - OFFSET, 4)
        \\  put(at + 8, wrote, 4)
        \\  put(at + 12, f, 4)
        \\  put(at + 16, polls, 4)
        \\  put(at + 20, REC, 2)
        \\  put(at + 22, STRIDE, 4)
        \\  put(at + 26, OFFSET, 2)
        \\  for i = 0, SEAM - 1 do
        \\    put(at + SEAM_AT + 4 * i, HEAD[i] or 0, 4)
        \\    put(at + SEAM_AT + 4 * (SEAM + i), TAIL[i] or 0, 4)
        \\  end
        \\  if LOG ~= 0 then put(LOG, nlog, 1) end
        \\  put(at + END_AT, read(BEAM, mem), 1)
        \\  put(at + END_AT + 1, read(CLOCK, mem) + read(CLOCK + 1, mem) * 256, 2)
        \\  emu.stop(0)
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  -- The first and last frames the pass plays, whole, so the seam between
        \\  -- two segments can be checked. Only at the ends: a digest is 8 KiB of
        \\  -- reads, which every frame of a whole segment cannot afford.
        \\  if LOG ~= 0 then
        \\    local b = read(BEAM, mem)
        \\    if beamWas ~= nil and b ~= beamWas then
        \\      if nlog < LOG_N then
        \\        put(LOG + 1 + 4 * nlog, f - OFFSET, 3); put(LOG + 4 + 4 * nlog, b, 1)
        \\      end
        \\      nlog = nlog + 1
        \\    end
        \\    beamWas = b
        \\  end
        \\  if f < SEAM then HEAD[f] = digest() end
        \\  if f >= STOP - SEAM and f < STOP then TAIL[f - (STOP - SEAM)] = digest() end
        \\  if f >= FIRST and wrote < COUNT and (f - FIRST) % STRIDE == 0 then
        \\    local at = AT + HDR + wrote * REC
        \\
    , .{});

    try writeRow(w);

    try w.print(
        \\    wrote = wrote + 1
        \\  end
        \\  f = f + 1
        \\  if f >= STOP then finish() end
        \\end, emu.eventType.endFrame)
        \\
        // `f` counts emulator frames and FIRST is offset, so the stop is too,
        // as it is in `run`'s timeout. Without it a pass wrote one row short and
        // `census` stopped there, taking it for the movie's end.
        //
        // The pass plays to STOP even after its last row: a strided window's
        // last row can be a stride short of the end, and the tail digests and
        // the end state are the end's (1.0 Step 24a).
    , .{});
}

/// The half of a pass script that is the same whichever kind of pass it is:
/// the memory handles, the button table, the savestate load, and the input
/// callback that re-drives the movie.
///
/// Shared because the world pass and the row pass differ only in what they
/// record. Every trap in here was paid for once and there is no second copy to
/// pay for it again.
fn writeDriver(w: *std.Io.Writer, offset: usize) !void {
    try w.print(
        \\local OFFSET = {d}
        \\
        \\local mem  = emu.memType.gameboyMemory
        \\local wram = emu.memType.gbWorkRam
        \\local sram = emu.memType.gbCartRam
        \\local read, write = emu.read, emu.write
        \\
        \\-- One button table per held byte, built once: the alternative is a
        \\-- table constructor per frame, which is most of the script's size.
        \\local B = {{}}
        \\for m = 0, 255 do
        \\  local t = {{}}
        \\  if m & 0x01 ~= 0 then t.a = true end
        \\  if m & 0x02 ~= 0 then t.b = true end
        \\  if m & 0x04 ~= 0 then t.select = true end
        \\  if m & 0x08 ~= 0 then t.start = true end
        \\  if m & 0x10 ~= 0 then t.right = true end
        \\  if m & 0x20 ~= 0 then t.left = true end
        \\  if m & 0x40 ~= 0 then t.up = true end
        \\  if m & 0x80 ~= 0 then t.down = true end
        \\  B[m] = t
        \\end
        \\
        \\-- `done` because emu.stop is not immediate: Mesen delivers at least one
        \\-- more endFrame after it, which without this guard records a frame past
        \\-- the end of the movie and indexes its input list out of bounds.
        \\local f, polls, loaded, wrote, done = 0, 0, false, 0, false
        \\
        \\-- emu.loadSavestate throws "This function must be called inside an exec
        \\-- memory operation callback for the main CPU" from anywhere else. $0040
        \\-- is the vblank vector, which the machine reaches on its own.
        \\emu.addMemoryCallback(function()
        \\  if not loaded then loaded = true; emu.loadSavestate(STATE); f = 0 end
        \\end, emu.callbackType.exec, 0x0040, 0x0040, emu.cpuType.gameboy, emu.memType.gameboyMemory)
        \\
        \\-- Row f - OFFSET, one-based. OFFSET is not a taste: see input_offset in
        \\-- src/gb_trace.zig for the column it was chosen against.
        \\emu.addEventCallback(function()
        \\  if not loaded then return end
        \\  polls = polls + 1
        \\  local m = string.byte(IN, f + 1 - OFFSET)
        \\  if m ~= nil then emu.setInput(B[m], 0) end
        \\end, emu.eventType.inputPolled)
        \\
        \\local function put(at, v, w)
        \\  for i = 0, w - 1 do write(at + i, (v >> (8 * i)) & 0xFF, sram) end
        \\  return at + w
        \\end
        \\
        \\-- FNV-1a over all 8 KiB of work RAM, the same constants and the same
        \\-- byte order src/tas.zig hashes with, so the column compares.
        \\local function digest()
        \\  local h = 2166136261
        \\  for a = 0, 8191 do h = ((h ~ read(a, wram)) * 16777619) & 0xFFFFFFFF end
        \\  return h
        \\end
        \\
        \\-- Blocks destroyed, counted every frame rather than on recorded ones.
        \\-- handleRespawningBlocks (01:5692) drops a slot the moment the block
        \\-- scrolls offscreen, so the array is current state and not history:
        \\-- sampling it at a stride steps straight over the frames it is set on.
        \\-- Registered before the recording callback, so a row reads this frame's
        \\-- answer and not last frame's.
        \\local blocksSeen, blocksWere = 0, 0
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  local live = 0
        \\  for i = 0, {d} - 1 do
        \\    if read(0x{X:0>4} + i * {d}, mem) ~= 0 then live = live + 1 end
        \\  end
        \\  if live > blocksWere then blocksSeen = blocksSeen + (live - blocksWere) end
        \\  blocksWere = live
        \\end, emu.eventType.endFrame)
        \\
    , .{ offset, block_slots, blocks_addr, block_slot_bytes });
}

/// The row body, emitted from `fields` so the layout is declared once.
///
/// It was written out by hand beside the table, which held only because nobody
/// had added a column yet. The pickup columns were the first, and adding them
/// twice is the mistake this removes rather than the one it documents.
fn writeRow(w: *std.Io.Writer) !void {
    for (fields) |f| switch (f.kind) {
        .input => try w.print("    at = put(at, string.byte(IN, f + 1 - OFFSET) or 0, {d})\n", .{f.width}),
        .blocks_seen => try w.print("    at = put(at, blocksSeen, {d})\n", .{f.width}),
        .live_blocks => try w.print(
            \\    local live = 0
            \\    for i = 0, {d} - 1 do
            \\      if read(0x{X:0>4} + i * {d}, mem) ~= 0 then live = live + 1 end
            \\    end
            \\    at = put(at, live, {d})
            \\
        , .{ block_slots, f.addr, block_slot_bytes, f.width }),
        .digest => try w.print("    at = put(at, digest(), {d})\n", .{f.width}),
        // Little-endian, `width` bytes up from `addr`, which is how every
        // multi-byte quantity the game keeps is laid out.
        .mem => {
            try w.print("    at = put(at, ", .{});
            var i: usize = f.width;
            while (i > 0) {
                i -= 1;
                if (i != f.width - 1) try w.print(" + ", .{});
                try w.print("read(0x{X:0>4}, mem)", .{f.addr + i});
                for (0..i) |_| try w.print(" * 256", .{});
            }
            try w.print(", {d})\n", .{f.width});
        },
    };
}

// ---- Reading a pass back --------------------------------------------------

/// Where a field's bytes sit inside one record.
pub fn offsetOf(comptime name: []const u8) usize {
    return comptime blk: {
        var n: usize = 0;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) break :blk n;
            n += f.width;
        }
        @compileError("no gb trace field named " ++ name);
    };
}

fn widthOf(comptime name: []const u8) u3 {
    return comptime blk: {
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) break :blk f.width;
        }
        @compileError("no gb trace field named " ++ name);
    };
}

/// One window of one movie, as the emulator left it.
pub const Pass = struct {
    /// The movie frame the window starts at.
    first: u32,
    /// Frames between recorded rows. 1 is every frame; a wider stride is how
    /// one pass censuses a whole movie, at the cost of stepping over the frame
    /// a thing happened on.
    stride: u32,
    /// How many frames the pass held the movie's rows back by. See
    /// `input_offset`. `first` and `Sample.frame` are movie frames, not
    /// emulator frames, so nothing outside this struct has to know it.
    offset: u16,
    /// Records actually written. Short of what was asked for means the movie
    /// ran out, not that the run failed.
    frames: usize,
    /// The frame the script stopped at, which is `first + frames` on a normal
    /// stop and the movie's length when the window ran past its end.
    frames_run: usize,
    /// `inputPolled` firings. Zero would mean the game never read the pad.
    polls: usize,
    /// The process exit code. `emu.stop(0)` is the only normal exit.
    code: u8,
    rows: []const u8,
    /// The game's own 8 KiB save bank, below the trace region: what the
    /// recording's saves left behind, which is a thing B11 asks to see.
    game_save: []const u8,
    /// Work RAM digests of the first and last `seam_frames` frames the pass
    /// played, zero where it did not play one. See `Seam`.
    head: [seam_frames]u32 = @splat(0),
    tail: [seam_frames]u32 = @splat(0),
    /// `samusBeam` and the BCD clock (hours high) on the last frame played.
    end_beam: u8 = 0,
    end_clock: u16 = 0,
    /// Every beam change the pass played through, when the window left room
    /// for the log (`beamLogAt`); null when it did not. `beam_dropped` counts
    /// changes past what the log holds.
    beam_log: ?[]const BeamChange = null,
    beam_dropped: usize = 0,
    backing: []u8,

    pub fn deinit(self: *Pass, allocator: std.mem.Allocator) void {
        if (self.beam_log) |l| allocator.free(l);
        allocator.free(self.backing);
        self.* = undefined;
    }

    pub fn get(self: Pass, i: usize, comptime name: []const u8) u32 {
        const w = comptime widthOf(name);
        const b = self.rows[i * record_bytes + offsetOf(name) ..];
        return switch (w) {
            1 => b[0],
            2 => std.mem.readInt(u16, b[0..2], .little),
            4 => std.mem.readInt(u32, b[0..4], .little),
            else => unreachable,
        };
    }

    /// How many frames behind the script's index the game's own joypad byte
    /// runs, measured from `$FF80` rather than reasoned about.
    ///
    /// `emu.setInput` from `inputPolled` lands after the frame's latch, so the
    /// byte the script set during frame f is not the byte the game acted on
    /// during f. Rather than write the answer down, every pass carries `pad`
    /// and this finds the shift that explains it. Null means no shift under
    /// `max_lag` explains the pass, which is a desync and not an alignment.
    ///
    /// **`$FF80` is a variable, not a port**, and the predicate is written
    /// around that. On a frame where the joypad routine does not run it still
    /// holds the previous answer — on par01, five frames of a released Start
    /// still reading `$08`. So a frame is consistent with a shift when the byte
    /// is either this frame's movie input or the byte the previous row carried,
    /// and only the frames that *changed* count as evidence. A stale frame can
    /// never produce a change, so nothing has to know which frames were stale.
    ///
    /// A pass with too few changed frames is not evidence of anything and is
    /// refused rather than passed — `min_changed`, and `padChanges` is how a
    /// caller tells "no evidence" from "the evidence disagrees".
    ///
    /// **Only at `stride` 1.** A strided pass cannot tell a change from the
    /// several changes it stepped over, so it returns null here rather than a
    /// verdict — an unchecked alignment, not a failed one, and the caller has
    /// to say which it is treating this as.
    pub fn lag(self: Pass, rec: Recording) ?usize {
        if (self.frames == 0 or self.stride != 1) return null;
        var shift: usize = 0;
        while (shift <= max_lag) : (shift += 1) {
            var changed: usize = 0;
            var ok = true;
            var prev: ?u8 = null;
            for (0..self.frames) |i| {
                const f = self.first + i * self.stride;
                const pad: u8 = @intCast(self.get(i, "pad"));
                defer prev = pad;
                if (f < shift or f - shift >= rec.inputs.len) continue;
                // A pass's first row has no row before it, so it cannot be a
                // change: a window that opens on a stale byte is not a desync.
                const was = prev orelse continue;
                if (pad == was) continue;
                changed += 1;
                if (pad != rec.inputs[f - shift]) {
                    ok = false;
                    break;
                }
            }
            if (ok and changed >= min_changed) return shift;
        }
        return null;
    }

    /// The game's own save bank as this pass left it: how many bytes are set,
    /// and a digest of the whole 8 KiB.
    ///
    /// **This is how a save is seen from outside the game.** B11 asks that the
    /// recording's saves appear in the trace, and no per-frame column can say
    /// so -- `saveFileToSRAM` writes a bank the trace region sits above, which
    /// is why records start at `game_sram_bytes` and not at zero. A pass that
    /// runs through a save leaves a different digest from one that stops before
    /// it, and that difference is the whole check.
    ///
    /// The savestate carries cart RAM, so frame 0 of a pass is not an empty
    /// bank: it is whatever the recording had saved when it was recorded. The
    /// digest is therefore compared between passes rather than against zero.
    pub fn saveBytes(self: Pass) usize {
        var n: usize = 0;
        for (self.game_save) |b| n += @intFromBool(b != 0);
        return n;
    }

    pub fn saveDigest(self: Pass) u32 {
        // FNV-1a, the same constants `wram_digest` hashes with.
        var h: u32 = 2166136261;
        for (self.game_save) |b| h = (h ^ b) *% 16777619;
        return h;
    }

    /// Frames on which the pad byte moved: the evidence `lag` has to work
    /// with. A window that sits inside a cutscene has almost none.
    pub fn padChanges(self: Pass) usize {
        var n: usize = 0;
        var prev: ?u8 = null;
        for (0..self.frames) |i| {
            const pad: u8 = @intCast(self.get(i, "pad"));
            defer prev = pad;
            // The first row is not a change, for the reason `lag` gives.
            const was = prev orelse continue;
            if (pad == was) continue;
            n += 1;
        }
        return n;
    }

    /// The pass as the table every other track is read as.
    ///
    /// `input` is the movie's held byte for the frame the game *acted on*,
    /// which is `frame - lag`. That is the same quantity `tas.Sample.input`
    /// carries on a replayed track, so the two are comparable rather than
    /// merely similarly named.
    pub fn samples(self: Pass, allocator: std.mem.Allocator, rec: Recording, shift: usize) Error![]tas.Sample {
        const out = try allocator.alloc(tas.Sample, self.frames);
        errdefer allocator.free(out);
        for (out, 0..) |*s, i| {
            const f: u32 = @intCast(self.first + i * self.stride);
            s.* = .{
                .frame = f,
                .input = if (f >= shift and f - shift < rec.inputs.len) rec.inputs[f - shift] else 0,
                .samus_y = @intCast(self.get(i, "samus_y")),
                .samus_x = @intCast(self.get(i, "samus_x")),
                .camera_y = @intCast(self.get(i, "camera_y")),
                .camera_x = @intCast(self.get(i, "camera_x")),
                .pose = @intCast(self.get(i, "pose")),
                .map_bank = @intCast(self.get(i, "map_bank")),
                .metroid_count = @intCast(self.get(i, "metroid_count")),
                .wram_digest = self.get(i, "wram_digest"),
            };
        }
        return out;
    }
};

/// Where two consecutive segments of one recording meet.
///
/// Recorded back to back -- the next started from the state the last one
/// stopped in -- the machine is continuous, and some frame of one's tail is
/// the same work RAM as some frame of the next one's head. Recorded with play
/// in between, nothing matches, and that is a gap rather than a failure: the
/// graders anchor on each segment's own state and need no continuous history.
pub const Seam = union(enum) {
    /// `tail[at_tail]` of the earlier segment is `head[at_head]` of the later.
    exact: struct { at_tail: u8, at_head: u8 },
    gap,
    /// A side has no digest: the pass did not play to its end.
    unchecked,
};

pub fn seam(tail: [seam_frames]u32, head: [seam_frames]u32) Seam {
    // A zero is a frame the pass did not play, never a digest: FNV-1a of 8 KiB
    // reaching exactly zero is not a case worth a flag.
    if (std.mem.indexOfScalar(u32, &tail, 0) != null) return .unchecked;
    if (std.mem.indexOfScalar(u32, &head, 0) != null) return .unchecked;
    // The latest tail frame first: if the machine sat still across several
    // frames, the join is the last of them.
    var t: usize = seam_frames;
    while (t > 0) {
        t -= 1;
        for (head, 0..) |h, j| {
            if (h == tail[t]) return .{ .exact = .{ .at_tail = @intCast(t), .at_head = @intCast(j) } };
        }
    }
    return .gap;
}

/// How many frames the movie's rows are held back by when they are driven in.
///
/// **Chosen by measurement, and the measurement is the game's own progress, not
/// the pad byte.** `Pass.lag` can only ever confirm the index the pass already
/// used — the emulator delivers whatever `emu.setInput` was handed, so `$FF80`
/// agrees with any offset — so it cannot pick one. What picks one is `$D089`:
/// a faithful replay of James's recording moves it 0→71 at 118, **71→70 at
/// 16 890 (the first Alpha)**, 70→0 at 25 891, 0→70 at 25 943 and **70→69 at
/// 73 392 (the second)**, and an offset that is wrong loses those.
///
/// Zero was tried first and does not reproduce them.
pub const input_offset: usize = 1;

/// How far the delivery check will look for the input shift. The measured shift
/// is zero; this is room for the question to have a different answer than the
/// one it had, not a range anything relies on.
pub const max_lag: usize = 4;

/// How many frames must have changed the pad byte before a shift is believed.
/// A window that spans a cutscene can legitimately have very few; a window with
/// none says nothing at all and is refused.
pub const min_changed: usize = 4;

// ---- The world at an anchor -----------------------------------------------
//
// A per-frame row says where Samus was. It does not say what she was standing
// on, and for this recording that is not a detail: the run shoots blocks out
// to descend, and the third screen is the first place it does. An anchor that
// carries position, camera and pose alone hands the port a room whose floor
// the trace does not have, so every anchor after the first destroyed block
// diverges on geometry -- and diverges from a capability the port does not
// have until Step 12b, which is the worst possible place for the blame to
// land.
//
// So a second kind of pass. It records, at each of a list of anchor frames,
// the whole background tilemap and the whole respawning-block array. That is
// 1 280 bytes an anchor against a 24 512-byte region, so a pass holds
// `max_worlds` of them and no more -- which is why this is a mode rather than
// four more columns on the row.

/// The Game Boy's background tilemap: the world the original's collision
/// actually reads. `samus_getTileIndex` goes through `getTilemapAddress`
/// (00:1FF5 and 00:22BC), so this is not a rendering detail.
///
/// `oracle.Settled.tiles` is already a `[1024]u8` of exactly this, and
/// `compareWorlds` already takes one, so a world pass is a second producer of
/// something the grader already consumes rather than a new shape.
pub const tilemap_addr: u16 = 0x9800;
pub const tilemap_bytes: usize = 1024;

/// `respawningBlockArray`, `$D900..$D9FF` in M2RoS's `SRC/ram/wram.asm`:
/// sixteen 16-byte slots, each a frame counter and a Y and X position. This is
/// the game's record of which blocks it has destroyed and owes back, and it is
/// the half of the world a tilemap cannot express -- a shot block is *absent*
/// from the tilemap, and only this says it is coming back.
pub const blocks_addr: u16 = 0xD900;
pub const blocks_bytes: usize = 256;
pub const block_slots: usize = 16;
pub const block_slot_bytes: usize = blocks_bytes / block_slots;

/// Per-world header: the movie frame, the two scroll registers, and which
/// memory type the tilemap was read through. Eight bytes so the payload after
/// it stays aligned to something a person can find in a hex dump.
pub const world_header_bytes: usize = 8;
pub const world_bytes: usize = world_header_bytes + tilemap_bytes + blocks_bytes;
pub const max_worlds: usize = (sram_bytes - records_at) / world_bytes;

/// A different magic from `magic`, so a read-back cannot mistake one kind of
/// pass for the other. They live at the same offset and are the same length.
pub const world_magic = [4]u8{ 'G', 'B', 'W', '1' };

/// How the script reached the tilemap, recorded rather than assumed.
///
/// **`$9800` is VRAM, and VRAM is not always readable.** The CPU bus returns
/// `$FF` for it during rendering mode 3, so a read through `gameboyMemory`
/// depends on where in the frame `endFrame` fires. Mesen exposes a video-RAM
/// memory type that is not gated that way; the script prefers it, falls back to
/// the bus when it is absent, and writes down which it used so a reader is
/// never guessing which of the two it is holding.
pub const Via = enum(u8) { cpu_bus = 0, video_ram = 1, _ };

pub const World = struct {
    /// The movie frame, not the emulator frame. See `Pass.offset`.
    frame: u32,
    scx: u8,
    scy: u8,
    via: Via,
    tiles: [tilemap_bytes]u8,
    blocks: [blocks_bytes]u8,

    /// Whether the tilemap came back as the `$FF` fill of a blocked VRAM read
    /// rather than as a room. Cheap, and it is the failure this is exposed to:
    /// a blocked read succeeds, returns 1 024 identical bytes, and every
    /// comparison downstream then agrees the two machines are in the same
    /// nothing.
    pub fn blank(self: World) bool {
        for (self.tiles[1..]) |t| {
            if (t != self.tiles[0]) return false;
        }
        return true;
    }

    /// Slots holding a block the game owes back. A slot's first byte is its
    /// frame counter, and zero is the game's own "empty".
    pub fn liveBlocks(self: World) usize {
        var n: usize = 0;
        for (0..block_slots) |i| {
            if (self.blocks[i * block_slot_bytes] != 0) n += 1;
        }
        return n;
    }
};

pub const WorldPass = struct {
    worlds: []World,
    /// The frame the script stopped at, and the process exit code, for the
    /// same reason `Pass` carries them: a pass that recorded nothing has to
    /// say whether it never got there or never ran.
    frames_run: usize,
    code: u8,

    pub fn deinit(self: *WorldPass, allocator: std.mem.Allocator) void {
        allocator.free(self.worlds);
        self.* = undefined;
    }

    pub fn find(self: WorldPass, frame: u32) ?*const World {
        for (self.worlds) |*w| {
            if (w.frame == frame) return w;
        }
        return null;
    }
};

/// The world pass's script: play the movie, and at each wanted frame copy the
/// tilemap and the block array into cart RAM.
pub fn writeWorldLua(
    w: *std.Io.Writer,
    rec: Recording,
    frames: []const u32,
    offset: usize,
) !void {
    if (frames.len == 0 or frames.len > max_worlds) return Error.TooManyFrames;
    var last: usize = 0;
    for (frames) |f| last = @max(last, @as(usize, f) + offset + 1);
    last = @min(last, rec.frames());

    try w.print(
        \\-- Generated by `zig build gbtrace -- ... world`. Do not edit.
        \\--
        \\-- The same replay as the frame pass, recording the world at a list of
        \\-- anchor frames instead of a window of rows. See src/gb_trace.zig.
        \\
        \\local STATE = 
    , .{});
    try writeLuaBytes(w, rec.state);

    try w.print("\nlocal IN = ", .{});
    try writeLuaBytes(w, rec.inputs[0..last]);

    try w.print("\n\nlocal WANT = {{", .{});
    // Keyed by *emulator* frame, which is the movie frame plus the offset, so
    // the lookup is the same arithmetic the row pass does on its window.
    for (frames, 0..) |f, i| try w.print("[{d}]={d},", .{ @as(usize, f) + offset, i });
    try w.print("}}\n\n", .{});

    try w.print(
        \\local AT, WB, HDR, N = {d}, {d}, {d}, {d}
        \\local TILES, BLOCKS = {d}, {d}
        \\
    , .{ header_at, world_bytes, header_bytes, frames.len, tilemap_bytes, blocks_bytes });

    try writeDriver(w, offset);

    try w.print(
        \\-- $9800 is VRAM and the CPU bus returns $FF for it during mode 3. The
        \\-- video-RAM memory type is not gated that way, so prefer it and write
        \\-- down which one was used -- see `Via` in src/gb_trace.zig.
        \\local vram = emu.memType.gbVideoRam
        \\local VIA = vram and 1 or 0
        \\local function tile(i)
        \\  if vram then return read(0x1800 + i, vram) end
        \\  return read(0x{X:0>4} + i, mem)
        \\end
        \\
        \\local function finish()
        \\  done = true
        \\  write(AT + 0, 71, sram); write(AT + 1, 66, sram)
        \\  write(AT + 2, 87, sram); write(AT + 3, 49, sram)
        \\  put(AT + 4, wrote, 4)
        \\  put(AT + 8, f, 4)
        \\  put(AT + 12, polls, 4)
        \\  emu.stop(0)
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  local slot = WANT[f]
        \\  if slot ~= nil then
        \\    local at = AT + HDR + slot * WB
        \\    at = put(at, f - OFFSET, 4)
        \\    at = put(at, read(0xFF43, mem), 1)
        \\    at = put(at, read(0xFF42, mem), 1)
        \\    at = put(at, VIA, 1)
        \\    at = put(at, 0, 1)
        \\    for i = 0, TILES - 1 do write(at + i, tile(i), sram) end
        \\    at = at + TILES
        \\    for i = 0, BLOCKS - 1 do write(at + i, read(0x{X:0>4} + i, mem), sram) end
        \\    wrote = wrote + 1
        \\  end
        \\  f = f + 1
        \\  if wrote >= N or f >= {d} then finish() end
        \\end, emu.eventType.endFrame)
        \\
    , .{ tilemap_addr, blocks_addr, last });
}

/// Take the world at each of `frames`, in one replay.
///
/// `frames` are movie frames and must fit one pass -- `max_worlds`. They do not
/// have to be sorted; the script keys them by frame rather than walking them in
/// order, so an unsorted list costs nothing and a duplicate is the same slot
/// written twice.
pub fn runWorlds(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    frames: []const u32,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
    lane: ?u8,
) !WorldPass {
    if (frames.len == 0 or frames.len > max_worlds) return Error.TooManyFrames;

    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeWorldLua(&lua.writer, rec, frames, offset);

    var through: usize = 0;
    for (frames) |f| through = @max(through, @as(usize, f) + offset);

    var code: u8 = 255;
    const bytes = try spawnPassIn(allocator, io, rom, rec, lua.written(), through, mesen_path, home, &code, lane);
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[header_at..][0..4], &world_magic)) return Error.DidNotRun;

    const wrote = std.mem.readInt(u32, bytes[header_at + 4 ..][0..4], .little);
    if (wrote > frames.len) return Error.ShortSaveFile;

    const worlds = try allocator.alloc(World, wrote);
    errdefer allocator.free(worlds);
    for (worlds, 0..) |*wd, i| {
        const at = records_at + i * world_bytes;
        wd.* = .{
            .frame = std.mem.readInt(u32, bytes[at..][0..4], .little),
            .scx = bytes[at + 4],
            .scy = bytes[at + 5],
            .via = @enumFromInt(bytes[at + 6]),
            .tiles = bytes[at + world_header_bytes ..][0..tilemap_bytes].*,
            .blocks = bytes[at + world_header_bytes + tilemap_bytes ..][0..blocks_bytes].*,
        };
    }

    return .{
        .worlds = worlds,
        .frames_run = std.mem.readInt(u32, bytes[header_at + 8 ..][0..4], .little),
        .code = code,
    };
}

// ---- Which enemy AIs the recording runs -------------------------------------
//
// Step 12f ports "the AIs the region needs", and the spawn lists cannot say
// which those are. Measured 2026-09-13: over the published route they name 6
// AIs, over the recording's 64-frame census 13, and with the neighbouring
// screens the loader also reads, 20 -- Gamma and Zeta Metroids among them. The
// census steps over short visits and the neighbour rule loads screens nobody
// scrolls to, so one under-counts and the other over-counts.
//
// So a fourth kind of pass, which asks the game instead. `enemy_commonAI` ends
// in `jp hl` at 02:5650 with HL loaded from `hEnemy.pAI` ($FFF1/$FFF2), and
// every AI any enemy runs goes through that one instruction. The script hooks
// it and keeps one record per distinct (AI, sprite) pair, accumulated over
// every frame of the window -- the `blocks_seen` argument again: a thing that
// happens between samples has to be counted, not sampled.

/// The `jp hl` that dispatches every enemy AI, 02:5650. Checked against the ROM
/// by a test rather than trusted: the nine bytes before it are `LD BC,$FFF2 /
/// LD A,(BC) / LD H,A / DEC C / LD A,(BC) / LD L,A`.
pub const ai_jump_addr: u16 = 0x5650;
pub const ai_jump_bank: usize = 2;
/// `hEnemy.pAI_low`/`_high` and `hEnemy.spriteType`, from M2RoS `SRC/ram/hram.asm`.
pub const ai_pointer_addr: u16 = 0xFFF1;
pub const ai_sprite_addr: u16 = 0xFFE3;

/// One distinct (AI, sprite) pair: where it was first dispatched, the window it
/// ran across, and how many times. Sixteen bytes.
pub const AiSeen = struct {
    ai: u16,
    sprite: u8,
    /// The map bank and Samus's cell at the first dispatch -- `tas.Room.of`'s
    /// arithmetic -- so a reader can find the enemy without a second pass.
    bank: u8,
    cell: u8,
    first: u32,
    last: u32,
    dispatches: u32,
};
pub const ai_seen_bytes: usize = 16;
/// Far below what the region holds; a census that fills it is refused rather
/// than truncated, which is what `AiPass.overflow` reports.
pub const max_ai_seen: usize = 256;
pub const ais_magic = [4]u8{ 'G', 'B', 'A', '1' };

pub const AiPass = struct {
    seen: []AiSeen,
    overflow: bool,
    frames_run: usize,
    code: u8,

    pub fn deinit(self: *AiPass, allocator: std.mem.Allocator) void {
        allocator.free(self.seen);
        self.* = undefined;
    }
};

/// The AI census script: play the movie to `through` and record every distinct
/// (AI, sprite) pair the dispatch jumps to on the way.
pub fn writeAiLua(w: *std.Io.Writer, rec: Recording, through: usize, offset: usize) !void {
    if (through == 0) return Error.TooManyFrames;
    const last = @min(through + offset, rec.frames());

    try w.print(
        \\-- Generated by `zig build gbtrace -- ... ais`. Do not edit.
        \\--
        \\-- The same replay as the frame pass, recording which enemy AIs the game
        \\-- dispatches instead of a window of rows. See src/gb_trace.zig.
        \\
        \\local STATE =
    , .{});
    try writeLuaBytes(w, rec.state);

    try w.print("\nlocal IN = ", .{});
    try writeLuaBytes(w, rec.inputs[0..last]);

    try w.print(
        \\
        \\
        \\local AT, HDR, SB, MAXN = {d}, {d}, {d}, {d}
        \\
    , .{ header_at, header_bytes, ai_seen_bytes, max_ai_seen });

    try writeDriver(w, offset);

    try w.print(
        \\local KEY, SEEN, n, overflow = {{}}, {{}}, 0, 0
        \\
        \\-- Any bank's code can execute $5650; only bank 2 has JP (HL) there, so
        \\-- the opcode under the PC is what says the dispatch is the one running.
        \\emu.addMemoryCallback(function()
        \\  if not loaded or done then return end
        \\  if read(0x{X:0>4}, mem) ~= 0xE9 then return end
        \\  local ai = read(0x{X:0>4}, mem) + read(0x{X:0>4}, mem) * 256
        \\  local sprite = read(0x{X:0>4}, mem)
        \\  local k = ai * 256 + sprite
        \\  local e = KEY[k]
        \\  if e == nil then
        \\    if n >= MAXN then overflow = 1; return end
        \\    local cell = (read(0xFFC1, mem) & 15) * 16 + (read(0xFFC3, mem) & 15)
        \\    e = {{ ai = ai, sprite = sprite, bank = read(0xD811, mem), cell = cell,
        \\          first = f - OFFSET, last = f - OFFSET, count = 0 }}
        \\    n = n + 1
        \\    SEEN[n] = e
        \\    KEY[k] = e
        \\  end
        \\  e.last = f - OFFSET
        \\  e.count = e.count + 1
        \\end, emu.callbackType.exec, 0x{X:0>4}, 0x{X:0>4}, emu.cpuType.gameboy, emu.memType.gameboyMemory)
        \\
        \\local function finish()
        \\  done = true
        \\  write(AT + 0, 71, sram); write(AT + 1, 66, sram)
        \\  write(AT + 2, 65, sram); write(AT + 3, 49, sram)
        \\  put(AT + 4, n, 4)
        \\  put(AT + 8, f, 4)
        \\  put(AT + 12, polls, 4)
        \\  put(AT + 16, overflow, 1)
        \\  for i = 1, n do
        \\    local e, at = SEEN[i], AT + HDR + (i - 1) * SB
        \\    at = put(at, e.ai, 2)
        \\    at = put(at, e.sprite, 1)
        \\    at = put(at, e.bank, 1)
        \\    at = put(at, e.cell, 1)
        \\    at = put(at, 0, 3)
        \\    at = put(at, e.first, 4)
        \\    at = put(at, e.last, 4)
        \\  end
        \\  -- The counts after the records, so a record stays sixteen bytes.
        \\  for i = 1, n do put(AT + HDR + MAXN * SB + (i - 1) * 4, SEEN[i].count, 4) end
        \\  emu.stop(0)
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  f = f + 1
        \\  if f >= {d} then finish() end
        \\end, emu.eventType.endFrame)
        \\
    , .{
        ai_jump_addr,         ai_pointer_addr, ai_pointer_addr + 1, ai_sprite_addr,
        ai_jump_addr,         ai_jump_addr,    last,
    });
}

pub fn runAis(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    through: usize,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
) !AiPass {
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeAiLua(&lua.writer, rec, through, offset);

    var code: u8 = 255;
    const bytes = try spawnPass(allocator, io, rom, rec, lua.written(), through + offset, mesen_path, home, &code);
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[header_at..][0..4], &ais_magic)) return Error.DidNotRun;

    const n = std.mem.readInt(u32, bytes[header_at + 4 ..][0..4], .little);
    if (n > max_ai_seen) return Error.ShortSaveFile;
    const seen = try allocator.alloc(AiSeen, n);
    errdefer allocator.free(seen);
    for (seen, 0..) |*s, i| {
        const at = records_at + i * ai_seen_bytes;
        const counts = records_at + max_ai_seen * ai_seen_bytes + i * 4;
        s.* = .{
            .ai = std.mem.readInt(u16, bytes[at..][0..2], .little),
            .sprite = bytes[at + 2],
            .bank = bytes[at + 3],
            .cell = bytes[at + 4],
            .first = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little),
            .last = std.mem.readInt(u32, bytes[at + 12 ..][0..4], .little),
            .dispatches = std.mem.readInt(u32, bytes[counts..][0..4], .little),
        };
    }
    return .{
        .seen = seen,
        .overflow = bytes[header_at + 16] != 0,
        .frames_run = std.mem.readInt(u32, bytes[header_at + 8 ..][0..4], .little),
        .code = code,
    };
}

// ---- The anchored pass: a whole reference, not a window --------------------
//
// The row pass records what a *track* is read as, and the world pass records
// what a *room* is. A `MovieRef` -- the thing every graded stretch is compared
// against -- needs both at once, and two more besides: where the game had put
// Samus on the frame before the stretch begins, and the two halves of "is this
// tile solid" that a door script had left in RAM.
//
// So this is a third kind of pass rather than a caller stitching the first two
// together. The pieces have to come from the same replay of the same frame, and
// two passes are two chances for them not to -- the same argument
// `referencesFromMovie` makes for taking fourteen references out of one replay
// instead of fourteen.
//
// **The frame record is `fields`, unchanged.** A reference frame reads four
// fewer columns than a row carries, and dropping them would save four bytes of
// a 24 512-byte budget in exchange for a second record layout to keep in step
// with. `oracle.Frame` is built from a `Pass` view over these rows, so a Mesen
// stretch and a Mesen census are the same table.

/// `$DC00`, the 256-byte block-type table the collision routines index with a
/// tile id -- `LD H,$DC / LD L,A / LD A,(HL)` at 00:$1F41 and its five
/// siblings. `oracle.Settled.coltab` is this and our `!ColTab` is the other
/// side of the comparison, so a reference that omitted it would compare two
/// machines walking through the same picture under different rules.
pub const coltab_addr: u16 = 0xDC00;
pub const coltab_bytes: usize = 256;

// The placement and camera addresses, duplicated from `room.zig` and
// `routines.zig` rather than imported, for the reason `savePath` duplicates the
// save folders and the three `oracle.Frame` columns duplicate theirs: those
// modules pull in the assembled engine, which has nothing to do with the Game
// Boy side. `room.placement` reads exactly these six, in this order.
const solidity_addr: u16 = 0xD056;
const map_bank_addr: u16 = 0xD811;
const warp_bank_addr: u16 = 0xD058;
const samus_screen_y_addr: u16 = 0xFFC1;
const samus_screen_x_addr: u16 = 0xFFC3;
const samus_pixel_y_addr: u16 = 0xFFC0;
const samus_pixel_x_addr: u16 = 0xFFC2;
const camera_pixel_y_addr: u16 = 0xFFC8;
const camera_screen_y_addr: u16 = 0xFFC9;
const camera_pixel_x_addr: u16 = 0xFFCA;
const camera_screen_x_addr: u16 = 0xFFCB;

/// The snapshot header: the movie frame, the scroll registers, which memory
/// type the tilemap came through, the collision threshold, `room.placement`'s
/// six bytes, the camera pair, how many frames the stretch recorded, and the
/// stretch's own origin. Twenty-four bytes, so the payload after it stays
/// findable in a hex dump.
pub const snapshot_header_bytes: usize = 24;
pub const snapshot_bytes: usize =
    snapshot_header_bytes + tilemap_bytes + blocks_bytes + coltab_bytes;

/// A third magic, for the reason `world_magic` is a second one: the three pass
/// kinds share an offset and a length, and a read-back that guessed wrong would
/// report a room's tiles as a run of frames.
pub const refs_magic = [4]u8{ 'G', 'B', 'R', '1' };

/// What a pass has to spend, once the game's own save bank and the pass header
/// are out of it.
pub const trace_region: usize = sram_bytes - records_at;

/// One stretch to take a reference for: where its frame 0 is in the movie, and
/// how far it runs. `oracle.Anchor` is the same pair with the grading side's
/// bookkeeping attached; this is only what the emulator has to be told.
pub const Stretch = struct {
    /// The movie frame the reference's frame 0 comes from. The snapshot is
    /// taken at the end of the frame *before* it, which is what
    /// `oracle.MovieCapture` does and what a cart's boot record is built from.
    origin: u32,
    frames: u32,
};

/// Bytes a set of stretches costs: one snapshot each, plus their frames.
pub fn refsBytes(stretches: []const Stretch) usize {
    var n: usize = stretches.len * snapshot_bytes;
    for (stretches) |s| n += @as(usize, s.frames) * record_bytes;
    return n;
}

pub fn refsFit(stretches: []const Stretch) bool {
    return stretches.len != 0 and refsBytes(stretches) <= trace_region;
}

/// Frames left for `n` stretches to share, once their snapshots are paid for.
///
/// One stretch is 1 560 bytes of snapshot against 24 512, so it keeps **850**
/// frames of the 27-byte record; four keep 676 between them. That is the budget
/// a sweep batches
/// against, and the reason a long stretch is capped by a caller that can say so
/// rather than truncated by a script that cannot.
pub fn refFramesBudget(n: usize) usize {
    const spent = n * snapshot_bytes;
    if (spent >= trace_region) return 0;
    return (trace_region - spent) / record_bytes;
}

/// The world and the placement at a stretch's frame 0, as the emulator left it.
///
/// Every field is one `oracle.Settled` has. They are read here so a reference
/// can be taken from Mesen rather than from a replay on our own Game Boy --
/// which for this recording stops being James's run at 28 796 frames.
pub const Snapshot = struct {
    /// The movie frame the snapshot was taken on: `origin - 1`.
    frame: u32,
    /// The stretch's own frame 0, written by the script rather than derived
    /// here, so a read-back of a pass that stopped early can tell a slot that
    /// was filled from one that never was.
    origin: u32,
    /// Frames the stretch actually recorded, which is short of what it asked
    /// for when the movie ran out.
    frames: u16,
    scx: u8,
    scy: u8,
    via: Via,
    /// `$D056`, the threshold every `CP (HL)` in the collision routines
    /// compares against.
    solid: u8,
    map_bank: u8,
    warp_bank: u8,
    screen_row: u8,
    screen_col: u8,
    pixel_y: u8,
    pixel_x: u8,
    camera_x: u16,
    camera_y: u16,
    tiles: [tilemap_bytes]u8,
    blocks: [blocks_bytes]u8,
    coltab: [coltab_bytes]u8,

    /// The same blocked-VRAM-read check `World.blank` makes, for the same
    /// reason: a gated read succeeds and hands back 1 024 identical bytes.
    pub fn blank(self: Snapshot) bool {
        for (self.tiles[1..]) |t| {
            if (t != self.tiles[0]) return false;
        }
        return true;
    }

    pub fn liveBlocks(self: Snapshot) usize {
        var n: usize = 0;
        for (0..block_slots) |i| {
            if (self.blocks[i * block_slot_bytes] != 0) n += 1;
        }
        return n;
    }
};

/// One stretch's reference: the world it starts in, and the frames it runs for.
///
/// `pass` is a `Pass` over this stretch's rows and nothing else -- `first` is
/// the stretch's origin, `stride` is 1, and `backing` is empty because the
/// bytes belong to the `RefsPass`. Everything that reads a `Pass` therefore
/// reads a stretch, `samples`, `lag` and `get` included.
pub const Reference = struct {
    snapshot: Snapshot,
    pass: Pass,
};

pub const RefsPass = struct {
    refs: []Reference,
    frames_run: usize,
    polls: usize,
    code: u8,
    /// The game's own save bank, below the trace region. See `Pass.game_save`.
    game_save: []const u8,
    backing: []u8,

    pub fn deinit(self: *RefsPass, allocator: std.mem.Allocator) void {
        allocator.free(self.refs);
        allocator.free(self.backing);
        self.* = undefined;
    }

    pub fn find(self: RefsPass, origin: u32) ?*const Reference {
        for (self.refs) |*r| {
            if (r.snapshot.origin == origin) return r;
        }
        return null;
    }
};

/// The anchored pass's script: play the movie once, and at each stretch take
/// the world and the placement at its origin minus one, then record its frames.
pub fn writeRefsLua(
    w: *std.Io.Writer,
    rec: Recording,
    stretches: []const Stretch,
    offset: usize,
) !void {
    if (stretches.len == 0) return Error.BadStretch;
    for (stretches) |s| {
        // Origin zero has no frame before it to snapshot, and a stretch of no
        // frames is a snapshot nobody grades against.
        if (s.origin == 0 or s.frames == 0) return Error.BadStretch;
    }
    if (!refsFit(stretches)) return Error.TooManyFrames;

    var last: usize = 0;
    for (stretches) |s| last = @max(last, @as(usize, s.origin) + s.frames + offset);
    last = @min(last, rec.frames());

    try w.print(
        \\-- Generated by `zig build gbtrace -- ... refs`. Do not edit.
        \\--
        \\-- The same replay as the row pass, taking a whole reference at each
        \\-- named stretch: the world and the placement at its origin minus one,
        \\-- then {d} bytes a frame for as far as it runs. See src/gb_trace.zig.
        \\
        \\local STATE = 
    , .{record_bytes});
    try writeLuaBytes(w, rec.state);

    try w.print("\nlocal IN = ", .{});
    try writeLuaBytes(w, rec.inputs[0..last]);

    try w.print(
        \\
        \\
        \\local AT, HDR, REC, SNAP = {d}, {d}, {d}, {d}
        \\local TILES, BLOCKS, COLTAB = {d}, {d}, {d}
        \\local N = {d}
        \\
    , .{
        header_at,     header_bytes, record_bytes, snapshot_bytes,
        tilemap_bytes, blocks_bytes, coltab_bytes, stretches.len,
    });

    // The snapshot and row bases, resolved here rather than in the script: the
    // stretches pack end to end, and arithmetic the script does not do is
    // arithmetic it cannot get wrong on a frame nobody is watching.
    //
    // Frames are *emulator* frames -- the movie frame plus the offset -- which
    // is the same arithmetic the world pass keys `WANT` by.
    try w.print("local S = {{\n", .{});
    var rows_at: usize = header_bytes + stretches.len * snapshot_bytes;
    for (stretches, 0..) |s, i| {
        try w.print(
            "  {{snap={d}, first={d}, count={d}, sbase={d}, rbase={d}, n=0}},\n",
            .{
                @as(usize, s.origin) - 1 + offset,
                @as(usize, s.origin) + offset,
                s.frames,
                header_bytes + i * snapshot_bytes,
                rows_at,
            },
        );
        rows_at += @as(usize, s.frames) * record_bytes;
    }
    try w.print("}}\n\n", .{});

    try writeDriver(w, offset);

    try w.print(
        \\-- $9800 is VRAM and the CPU bus returns $FF for it during mode 3. See
        \\-- `Via`: prefer the ungated type, and write down which one was used.
        \\local vram = emu.memType.gbVideoRam
        \\local VIA = vram and 1 or 0
        \\local function tile(i)
        \\  if vram then return read(0x1800 + i, vram) end
        \\  return read(0x{X:0>4} + i, mem)
        \\end
        \\
        \\local rows = 0
        \\
        \\-- The per-stretch row count is stamped at the end rather than kept
        \\-- current: it is only ever read once, and a stretch that stops short
        \\-- because the movie ran out has to say so from outside its own loop.
        \\local function finish()
        \\  done = true
        \\  for i = 1, N do put(AT + S[i].sbase + 18, S[i].n, 2) end
        \\  write(AT + 0, 71, sram); write(AT + 1, 66, sram)
        \\  write(AT + 2, 82, sram); write(AT + 3, 49, sram)
        \\  put(AT + 4, N, 4)
        \\  put(AT + 8, wrote, 4)
        \\  put(AT + 12, f, 4)
        \\  put(AT + 16, polls, 4)
        \\  put(AT + 20, REC, 2)
        \\  put(AT + 22, OFFSET, 2)
        \\  put(AT + 24, rows, 4)
        \\  emu.stop(0)
        \\end
        \\
    , .{tilemap_addr});

    try w.print(
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  local full = true
        \\  for i = 1, N do
        \\    local s = S[i]
        \\    if f == s.snap then
        \\      local at = AT + s.sbase
        \\      at = put(at, f - OFFSET, 4)
        \\      at = put(at, read(0xFF43, mem), 1)
        \\      at = put(at, read(0xFF42, mem), 1)
        \\      at = put(at, VIA, 1)
        \\      at = put(at, read(0x{X:0>4}, mem), 1)
        \\      at = put(at, read(0x{X:0>4}, mem), 1)
        \\      at = put(at, read(0x{X:0>4}, mem), 1)
        \\      at = put(at, read(0x{X:0>4}, mem), 1)
        \\      at = put(at, read(0x{X:0>4}, mem), 1)
        \\      at = put(at, read(0x{X:0>4}, mem), 1)
        \\      at = put(at, read(0x{X:0>4}, mem), 1)
        \\      at = put(at, read(0x{X:0>4}, mem) + read(0x{X:0>4}, mem) * 256, 2)
        \\      at = put(at, read(0x{X:0>4}, mem) + read(0x{X:0>4}, mem) * 256, 2)
        \\      at = at + 2
        \\      at = put(at, s.first - OFFSET, 4)
        \\      at = AT + s.sbase + {d}
        \\      for k = 0, TILES - 1 do write(at + k, tile(k), sram) end
        \\      at = at + TILES
        \\      for k = 0, BLOCKS - 1 do write(at + k, read(0x{X:0>4} + k, mem), sram) end
        \\      at = at + BLOCKS
        \\      for k = 0, COLTAB - 1 do write(at + k, read(0x{X:0>4} + k, mem), sram) end
        \\      wrote = wrote + 1
        \\    elseif f >= s.first and s.n < s.count then
        \\      local at = AT + s.rbase + s.n * REC
        \\
    , .{
        solidity_addr,        map_bank_addr,         warp_bank_addr,
        samus_screen_y_addr,  samus_screen_x_addr,   samus_pixel_y_addr,
        samus_pixel_x_addr,   camera_pixel_x_addr,   camera_screen_x_addr,
        camera_pixel_y_addr,  camera_screen_y_addr,  snapshot_header_bytes,
        blocks_addr,          coltab_addr,
    });

    try writeRow(w);

    try w.print(
        \\      s.n = s.n + 1
        \\      rows = rows + 1
        \\    end
        \\    if s.n < s.count then full = false end
        \\  end
        \\  f = f + 1
        \\  if full or f >= {d} then finish() end
        \\end, emu.eventType.endFrame)
        \\
    , .{last});
}

/// Take one reference per stretch, out of a single replay.
///
/// `stretches` must fit one pass -- `refsFit` -- and every origin must be at
/// least 1, because the snapshot is taken on the frame before it. They do not
/// have to be sorted: every stretch is checked on every frame, which is a
/// handful of Lua comparisons against a replay that is already running.
///
/// A stretch the replay never reached is left out of `refs` rather than
/// returned as zeros, which is the same choice `referencesFromMovie` makes in
/// returning a slot it could not fill as null: one bad anchor out of fourteen
/// should not lose the other thirteen.
pub fn runRefs(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    stretches: []const Stretch,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
) !RefsPass {
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeRefsLua(&lua.writer, rec, stretches, offset);

    var through: usize = 0;
    for (stretches) |s| through = @max(through, @as(usize, s.origin) + s.frames + offset);

    var code: u8 = 255;
    const bytes = try spawnPass(allocator, io, rom, rec, lua.written(), through, mesen_path, home, &code);
    errdefer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[header_at..][0..4], &refs_magic)) return Error.DidNotRun;
    if (records_at + refsBytes(stretches) > sram_bytes) return Error.ShortSaveFile;

    const took = std.mem.readInt(u32, bytes[header_at + 8 ..][0..4], .little);
    if (took > stretches.len) return Error.ShortSaveFile;
    const frames_run = std.mem.readInt(u32, bytes[header_at + 12 ..][0..4], .little);
    const polls = std.mem.readInt(u32, bytes[header_at + 16 ..][0..4], .little);

    var refs = try allocator.alloc(Reference, stretches.len);
    errdefer allocator.free(refs);
    var kept: usize = 0;
    var rows_at: usize = records_at + stretches.len * snapshot_bytes;
    for (stretches, 0..) |st, i| {
        const at = records_at + i * snapshot_bytes;
        const body = at + snapshot_header_bytes;
        const rows = rows_at;
        rows_at += @as(usize, st.frames) * record_bytes;
        const origin = std.mem.readInt(u32, bytes[at + 20 ..][0..4], .little);
        const n = std.mem.readInt(u16, bytes[at + 18 ..][0..2], .little);
        // The slot was never filled: the replay stopped before this stretch's
        // origin, or before it at all. `origin` is written by the snapshot and
        // the save file is cleared before the run, so a match is proof.
        if (origin != st.origin or n == 0) continue;
        refs[kept] = .{
            .snapshot = .{
                .frame = std.mem.readInt(u32, bytes[at..][0..4], .little),
                .origin = origin,
                .frames = n,
                .scx = bytes[at + 4],
                .scy = bytes[at + 5],
                .via = @enumFromInt(bytes[at + 6]),
                .solid = bytes[at + 7],
                .map_bank = bytes[at + 8],
                .warp_bank = bytes[at + 9],
                .screen_row = bytes[at + 10],
                .screen_col = bytes[at + 11],
                .pixel_y = bytes[at + 12],
                .pixel_x = bytes[at + 13],
                .camera_x = std.mem.readInt(u16, bytes[at + 14 ..][0..2], .little),
                .camera_y = std.mem.readInt(u16, bytes[at + 16 ..][0..2], .little),
                .tiles = bytes[body..][0..tilemap_bytes].*,
                .blocks = bytes[body + tilemap_bytes ..][0..blocks_bytes].*,
                .coltab = bytes[body + tilemap_bytes + blocks_bytes ..][0..coltab_bytes].*,
            },
            .pass = .{
                .first = st.origin,
                .stride = 1,
                .offset = @intCast(offset),
                .frames = n,
                .frames_run = frames_run,
                .polls = polls,
                .code = code,
                .rows = bytes[rows..][0 .. @as(usize, n) * record_bytes],
                .game_save = bytes[0..game_sram_bytes],
                // The bytes belong to the `RefsPass`; a stretch is a view.
                .backing = &.{},
            },
        };
        kept += 1;
    }
    refs = try allocator.realloc(refs, kept);

    return .{
        .refs = refs,
        .frames_run = frames_run,
        .polls = polls,
        .code = code,
        .game_save = bytes[0..game_sram_bytes],
        .backing = bytes,
    };
}

/// The pass as a table, `tas.tsv`'s columns plus the ones only this side has.
///
/// The first ten columns are `tas.tsv`'s, in its order, so a Mesen table and a
/// replayed one can be diffed against each other directly; the pickups are
/// appended rather than interleaved for the same reason.
pub fn tsv(
    allocator: std.mem.Allocator,
    pass: Pass,
    samples: []const tas.Sample,
) ![]u8 {
    std.debug.assert(samples.len == pass.frames);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "frame\tinput\tsamus_y\tsamus_x\tcamera_y\tcamera_x\tpose\tbank\tmetroids\twram" ++
            "\titems\tetanks\tmissiles_max\tblocks\tblocks_seen\tfacing\tcounter\twater\n",
        .{},
    );
    for (samples, 0..) |s, i| {
        try out.print(allocator, "{d}\t{X:0>2}\t{X:0>4}\t{X:0>4}\t{X:0>4}\t{X:0>4}\t{X:0>2}\t{X:0>2}\t{d}\t{X:0>8}" ++
            "\t{X:0>2}\t{d}\t{d}\t{d}\t{d}\t{X:0>2}\t{X:0>2}\t{X:0>2}\n", .{
            s.frame,    s.input,         s.samus_y,   s.samus_x,
            s.camera_y, s.camera_x,      s.pose,      s.map_bank,
            s.metroid_count,             s.wram_digest,
            pass.get(i, "items"),        pass.get(i, "etanks"),
            pass.get(i, "missiles_max"),         pass.get(i, "live_blocks"),
            pass.get(i, "blocks_seen"),          pass.get(i, "facing"),
            pass.get(i, "counter"),              pass.get(i, "water"),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// How far behind the movie's own row index `$FF80` runs, when a window has
/// too few pad changes to measure it.
///
/// **Zero, measured on the recording's own first 900 frames** -- `Pass.lag`
/// answers 0 there against 899 rows, and the row pass prints it. It is not the
/// same quantity as `input_offset`: that one is where the *script* reads its
/// input list, and this one is where the *game* is by the time the row is
/// taken. Conflating them was this function's first bug, and it presented as
/// `InputMisaligned` on a window that was perfectly aligned.
pub const pad_lag: usize = 0;

/// A stride-1 track of a window, taken in as many passes as it needs.
///
/// `oracle.anchorsFrom` reads intervals between adjacent frames, so it needs
/// every frame -- `Track.stride` refuses a strided track rather than
/// mis-anchoring on one. One pass holds `max_frames` rows, so a longer window
/// is several passes, and **each is a full replay from the movie's start**:
/// that is what the horizon costs, at roughly 700 frames a second.
///
/// Safe to stitch, and measured rather than assumed: two identical headless
/// runs agree on every census column across all 76 951 frames, so consecutive
/// windows are windows onto one run and not onto two.
///
/// Every window's alignment is checked against the game's own `$FF80` rather
/// than trusted. A window that carries evidence and contradicts it comes back
/// as `Error.InputMisaligned`; one with too few pad changes to be evidence --
/// a cutscene -- takes `pad_lag` and says so through `checked`. See `Pass.lag`
/// and `Pass.padChanges`, which are what tell those two apart.
pub const Census = struct {
    samples: []tas.Sample,
    /// The lag every window agreed on, or `pad_lag` when none carried evidence.
    lag: usize,
    /// Windows that actually measured it. Zero means nothing was checked.
    checked: usize,
    passes: usize,

    pub fn deinit(self: *Census, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        self.* = undefined;
    }
};

pub fn census(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    first: usize,
    count: usize,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
) !Census {
    var out: std.ArrayList(tas.Sample) = .empty;
    errdefer out.deinit(allocator);

    var lag: ?usize = null;
    var checked: usize = 0;
    var passes: usize = 0;
    var at = first;
    while (at < first + count) {
        const want = @min(max_frames, first + count - at);
        var pass = try run(allocator, io, rom, rec, at, want, 1, offset, mesen_path, home, null);
        defer pass.deinit(allocator);
        passes += 1;
        if (pass.frames == 0) break;

        // Null from `lag` is either "no shift explains this window" or "this
        // window has no evidence". Only the first is a misalignment, and
        // `padChanges` is what tells them apart.
        const measured = pass.lag(rec);
        if (measured == null and pass.padChanges() >= min_changed) return Error.InputMisaligned;
        if (measured) |m| {
            if (lag) |was| {
                // Two windows of one replay disagreeing about where the game is
                // relative to the movie is not an alignment question; it is a
                // desync, and stitching them would hide it.
                if (m != was) return Error.InputMisaligned;
            } else lag = m;
            checked += 1;
        }

        const samples = try pass.samples(allocator, rec, lag orelse pad_lag);
        defer allocator.free(samples);
        try out.appendSlice(allocator, samples);

        at += pass.frames;
        // The movie ran out inside this window; nothing follows it.
        if (pass.frames < want) break;
    }
    return .{
        .samples = try out.toOwnedSlice(allocator),
        .lag = lag orelse pad_lag,
        .checked = checked,
        .passes = passes,
    };
}

// ---- Where Mesen puts the file --------------------------------------------

/// The same folders `snes_trace.savePath` probes, for the same measured reason:
/// Mesen2 has no command line option for the save directory and `HOME` does not
/// move it on macOS. Duplicated rather than imported because that module pulls
/// in the assembled engine, which has nothing to do with the Game Boy side.
const save_folders = [_][]const u8{
    "Library/Application Support/MesenCE/Saves",
    "Library/Application Support/Mesen2/Saves",
    ".config/MesenCE/Saves",
    ".config/Mesen2/Saves",
};

pub fn savePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    rom_stem: []const u8,
) Error![]u8 {
    if (home.len == 0) return Error.NoSaveFolder;
    for (save_folders) |rel| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, rel });
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        dir.close(io);
        defer allocator.free(path);
        return try std.fmt.allocPrint(allocator, "{s}/{s}.srm", .{ path, rom_stem });
    }
    return Error.NoSaveFolder;
}

// ---- Running one pass -----------------------------------------------------

/// Headless replay measures at roughly 700 frames a second, so a pass that has
/// to fast-forward through a whole 77 000-frame movie takes under two minutes.
/// The timeout is that, with room, and is a backstop rather than a budget.
fn timeoutSeconds(frames: usize) usize {
    return 60 + frames / 200;
}

/// Everything a pass does that is neither "which script" nor "how to read the
/// bytes back": stamp a copy of the ROM, write the script beside it, clear the
/// save file, run Mesen headless, and hand back what it left.
///
/// Split out when the world pass arrived, because the two passes differ only
/// in those two things and the rest is a list of measured traps -- the stamped
/// copy so the user's `metroid2.srm` is never opened, the delete so a stale
/// file cannot read as a successful run, the timeout scaled to the prefix the
/// script has to play through.
fn spawnPass(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    lua_src: []const u8,
    through: usize,
    mesen_path: []const u8,
    home: []const u8,
    code: *u8,
) ![]u8 {
    return spawnPassIn(allocator, io, rom, rec, lua_src, through, mesen_path, home, code, null);
}

/// Where Mesen's answers are kept (1.0 Step 18c2). A pass is a pure function
/// of the stamped cart, the script (which carries the recording's input) and
/// the emulator, so its save file is filed under a hash of the three and a
/// second asking is read back instead of replayed. Only a clean run
/// (`emu.stop(0)`) is kept: a timeout or a crash is asked again.
pub const cache_dir = out_dir ++ "/mesen-cache";

/// `spawnPass` in a lane of its own. Passes run side by side each need their
/// own file names: Mesen names the save file after the cart, and the save file
/// is how a pass reports. `lane` null is the one-at-a-time name, `stem`.
fn spawnPassIn(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    lua_src: []const u8,
    through: usize,
    mesen_path: []const u8,
    home: []const u8,
    code: *u8,
    lane: ?u8,
) ![]u8 {
    try rec.checkCartridge(rom);

    const stamped = try allocator.dupe(u8, rom);
    defer allocator.free(stamped);
    stampRam(stamped);

    const exe = try std.Io.Dir.cwd().statFile(io, mesen_path, .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(stamped);
    h.update(lua_src);
    h.update(mesen_path);
    h.update(std.mem.asBytes(&exe.size));
    h.update(std.mem.asBytes(&exe.mtime.nanoseconds));
    const key = std.fmt.bytesToHex(h.finalResult(), .lower);
    const cached = try std.fmt.allocPrint(allocator, "{s}/{s}.srm", .{ cache_dir, key });
    defer allocator.free(cached);
    if (std.Io.Dir.cwd().readFileAlloc(io, cached, allocator, .limited(sram_bytes * 2))) |bytes| {
        code.* = 0;
        return bytes;
    } else |e| if (e != error.FileNotFound) return e;

    var name_buf: [32]u8 = undefined;
    const name = if (lane) |l| try std.fmt.bufPrint(&name_buf, "{s}-{d}", .{ stem, l }) else stem;
    const cart = try std.fmt.allocPrint(allocator, "{s}/{s}.gb", .{ out_dir, name });
    defer allocator.free(cart);
    const script = try std.fmt.allocPrint(allocator, "{s}/{s}.lua", .{ out_dir, name });
    defer allocator.free(script);

    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cart, .data = stamped });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = lua_src });

    const srm = try savePath(allocator, io, home, name);
    defer allocator.free(srm);
    // "Absent means it did not run": a stale file from an earlier pass would
    // read as a successful one, and did once, on the SNES side.
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};

    const timeout = try std.fmt.allocPrint(allocator, "--timeout={d}", .{timeoutSeconds(through)});
    defer allocator.free(timeout);

    var child = try std.process.spawn(io, .{
        .argv = &.{ mesen_path, cart, "--testrunner", script, timeout },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    code.* = if (term == .exited) @truncate(term.exited) else 255;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, srm, allocator, .limited(sram_bytes * 2)) catch
        return Error.NoSaveFile;
    errdefer allocator.free(bytes);
    if (bytes.len < sram_bytes) return Error.ShortSaveFile;
    if (code.* == 0) {
        try std.Io.Dir.cwd().createDirPath(io, cache_dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cached, .data = bytes });
    }
    return bytes;
}

// ---- The status bar, at a list of frames -----------------------------------
//
// Step 13b. The window is not in any column a frame pass records -- every
// column is WRAM -- and it is the one picture the HUD oracle wants from a
// machine this repository did not build. So a third kind of pass: the same
// replay, recording at each listed frame the window tilemap's first row and
// the bytes `VBlank_updateStatusBar` draws it from.

/// The HUD bytes, in record order.
pub const hud_addrs = [_]u16{
    0xD050, // samusEnergyTanks
    0xD051, 0xD052, // samusCurHealth
    0xD053, 0xD054, // samusCurMissiles
    0xD084, 0xD085, // samusDispHealth
    0xD086, 0xD087, // samusDispMissiles
    0xD09A, // metroidCountDisplayed
    0xD096, // metroidCountShuffleTimer
    0xD06C, // itemCollected
    0xD06D, // itemCollectionFlag
    0xD08E, // doorIndexLow
    0xFF9B, // gameMode
};
pub const hud_tiles: usize = 0x14;
pub const hud_header_bytes: usize = 4;
pub const hud_record_bytes: usize = hud_header_bytes + hud_tiles + hud_addrs.len;
pub const max_huds: usize = (sram_bytes - records_at) / hud_record_bytes;
pub const hud_magic = [4]u8{ 'G', 'B', 'H', '1' };

pub const HudFrame = struct {
    /// The movie frame.
    frame: u32,
    tiles: [hud_tiles]u8,
    bytes: [hud_addrs.len]u8,

    pub fn get(self: HudFrame, addr: u16) u8 {
        for (hud_addrs, 0..) |a, i| {
            if (a == addr) return self.bytes[i];
        }
        unreachable;
    }
};

pub fn writeHudLua(w: *std.Io.Writer, rec: Recording, frames: []const u32, offset: usize) !void {
    if (frames.len == 0 or frames.len > max_huds) return Error.TooManyFrames;
    var last: usize = 0;
    for (frames) |f| last = @max(last, @as(usize, f) + offset + 1);
    last = @min(last, rec.frames());

    try w.print(
        \\-- Generated by src/gb_trace.zig's HUD pass. Do not edit.
        \\
        \\local STATE = 
    , .{});
    try writeLuaBytes(w, rec.state);
    try w.print("\nlocal IN = ", .{});
    try writeLuaBytes(w, rec.inputs[0..last]);
    try w.print("\n\nlocal WANT = {{", .{});
    for (frames, 0..) |f, i| try w.print("[{d}]={d},", .{ @as(usize, f) + offset, i });
    try w.print("}}\nlocal ADDRS = {{", .{});
    for (hud_addrs) |a| try w.print("0x{X:0>4},", .{a});
    try w.print(
        \\}}
        \\local AT, RB, HDR, N, TILES = {d}, {d}, {d}, {d}, {d}
        \\
    , .{ header_at, hud_record_bytes, header_bytes, frames.len, hud_tiles });
    try writeDriver(w, offset);
    try w.print(
        \\-- The window's tilemap, through the video-RAM type for the reason the
        \\-- world pass gives: the bus returns $FF for VRAM during mode 3.
        \\local vram = emu.memType.gbVideoRam
        \\
        \\local function finish()
        \\  done = true
        \\  write(AT + 0, 71, sram); write(AT + 1, 66, sram)
        \\  write(AT + 2, 72, sram); write(AT + 3, 49, sram)
        \\  put(AT + 4, wrote, 4)
        \\  put(AT + 8, f, 4)
        \\  emu.stop(0)
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  local slot = WANT[f]
        \\  if slot ~= nil then
        \\    local at = AT + HDR + slot * RB
        \\    at = put(at, f - OFFSET, 4)
        \\    for i = 0, TILES - 1 do write(at + i, read(0x1C00 + i, vram), sram) end
        \\    at = at + TILES
        \\    for i = 1, #ADDRS do write(at + i - 1, read(ADDRS[i], mem), sram) end
        \\    wrote = wrote + 1
        \\  end
        \\  f = f + 1
        \\  if wrote >= N or f >= {d} then finish() end
        \\end, emu.eventType.endFrame)
        \\
    , .{last});
}

/// The window row and its bytes at each of `frames`, in one replay.
pub fn runHud(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    frames: []const u32,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
) ![]HudFrame {
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeHudLua(&lua.writer, rec, frames, offset);

    var through: usize = 0;
    for (frames) |f| through = @max(through, @as(usize, f) + offset);

    var code: u8 = 255;
    const bytes = try spawnPass(allocator, io, rom, rec, lua.written(), through, mesen_path, home, &code);
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[header_at..][0..4], &hud_magic)) return Error.DidNotRun;
    const wrote = std.mem.readInt(u32, bytes[header_at + 4 ..][0..4], .little);
    if (wrote > frames.len) return Error.ShortSaveFile;

    const out = try allocator.alloc(HudFrame, wrote);
    for (out, 0..) |*h, i| {
        const at = records_at + i * hud_record_bytes;
        h.* = .{
            .frame = std.mem.readInt(u32, bytes[at..][0..4], .little),
            .tiles = bytes[at + hud_header_bytes ..][0..hud_tiles].*,
            .bytes = bytes[at + hud_header_bytes + hud_tiles ..][0..hud_addrs.len].*,
        };
    }
    return out;
}

// ---- A Metroid fight, event by event ---------------------------------------
//
// Step 13d. The enemy oracle hands an Alpha its missiles at ticks a case names,
// and the plan asks for the recording's own. No frame pass carries them: a hit
// is a one-frame handshake between four collision bytes, and the fight's state
// is five globals and one slot. So a fifth kind of pass: across a window, one
// record on every frame where any of `kill_watch` changed -- which is every
// hurt, every stage of the death and every step of the timer, and not the
// lunge, whose slot bytes change on every pass and are carried along unwatched.

/// Watched: a change in any of these writes a record.
pub const kill_watch = [_]u16{
    0xC41B, // metroid_postDeathTimer
    0xC41C, // metroid_state
    0xC463, // cutsceneActive
    0xC464, // alpha_stunCounter
    0xC465, // metroid_fightActive
    0xC46D, // enemy_weaponType, the AI-facing copy
    0xC46E, // enemy_weaponDir
    0xD089, // metroidCountReal
    0xD09A, // metroidCountDisplayed
    // Step 14: what a kill sets going after the fight is over. The quake is
    // 01:$5857's countdown and 01:$79EF's shake; the two interruption bytes are
    // the audio driver's, which the port has no copy of, so what they hold
    // around a quake is read here rather than inferred from bank 4.
    0xD091, // nextEarthquakeTimer
    0xD083, // earthquakeTimer
    0xD0A5, // songRequest_afterEarthquake
    0xCEDE, // songInterruptionRequest
    0xCEDF, // songInterruptionPlaying
    // 1.0 Step 13: Arachnus keeps its health out of the slot, which holds $FF.
    0xC394, // arachnus_health
    // 1.0 Step 14: the Gamma's own stun counter.
    0xC46A, // gamma_stunCounter
    // 1.0 Step 15: the Zeta's.
    0xC46C, // zeta_stunCounter
    // 1.0 Step 16: the Omega's.
    0xC462, // omega_stunCounter
    // 1.0 Step 17: the larvae's, shared by all eight.
    0xC473, // larva_hurtAnimCounter
    0xC474, // larva_bombState
    0xC475, // larva_latchState
    // 1.0 Step 20d: the Queen's state, whose $11 to $16 is her death, and
    // `queen_roomFlag`, which `EXIT_QUEEN` clears and a `WARP` takes to $01.
    0xC3C3, // queen_state
    0xD08B, // queen_roomFlag
    // 1.0 Step 22: the ending. `gameMode`'s $12 and $13, Samus's credits
    // state and the scroll's done flag.
    0xFF9B, // gameMode
    0xD097, // credits_samusAnimState
    0xD09F, // credits_scrollingDone
};
/// Carried: read on a recorded frame, never a reason to record one.
pub const kill_carry = [_]u16{
    0xFF97, // frameCounter
    0xD020, // samusPose
    0xD811, // the map bank
    0xC205, // scrollY, which the quake shakes
    0xCEDC, // songRequest
    0xD092, // currentRoomSong
    // 1.0 Step 14: the room's loaded state, `$D808`-`$D814` (what a save keeps),
    // so a kill's table says which tileset the fight was in. It is how the
    // wrong rock in Metroid 01's warp was told apart from the room's own.
    0xD808, 0xD809, 0xD80A, 0xD80B, 0xD80C, 0xD80D, 0xD80E, 0xD80F, 0xD810, 0xD811, 0xD812, 0xD813, 0xD814,
};
/// The fighter's slot, found by its AI word: +$00 status, +$01 Y, +$02 X, +$03
/// sprite, +$07 generalVar (Arachnus's state), +$09 counter, +$0A state, +$0C
/// health, +$1C spawn flag. The health and the flag are watched; the rest are
/// carried.
pub const kill_slot_fields = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x07, 0x09, 0x0A, 0x0C, 0x1C };
pub const kill_slot_watched = [_]u8{ 0x0C, 0x1C };
/// The two Alpha AIs, `enemy_oracle.cases`' keys, Arachnus (1.0 Step 13) and
/// the Gamma (1.0 Step 14), the Zeta (1.0 Step 15), the Omega (1.0 Step 16)
/// and the larva (1.0 Step 17), the first live one of a room's.
pub const kill_ais = [_]u16{ 0x6BB2, 0x6C44, 0x5109, 0x6F60, 0x7276, 0x7631, 0x7A4F };
/// Frame, the slot index or `$FF`, then the three byte lists.
pub const kill_record_bytes: usize = 4 + 1 + kill_watch.len + kill_carry.len + kill_slot_fields.len;
pub const max_kill_records: usize = (sram_bytes - records_at) / kill_record_bytes;
pub const kills_magic = [4]u8{ 'G', 'B', 'K', '1' };

pub const KillEvent = struct {
    frame: u32,
    slot: u8,
    watch: [kill_watch.len]u8,
    carry: [kill_carry.len]u8,
    fields: [kill_slot_fields.len]u8,

    pub fn get(self: KillEvent, addr: u16) u8 {
        for (kill_watch, 0..) |a, i| if (a == addr) return self.watch[i];
        for (kill_carry, 0..) |a, i| if (a == addr) return self.carry[i];
        unreachable;
    }
    pub fn field(self: KillEvent, off: u8) u8 {
        for (kill_slot_fields, 0..) |o, i| if (o == off) return self.fields[i];
        unreachable;
    }
};

pub const KillPass = struct {
    events: []KillEvent,
    /// Records that did not fit: nonzero is a window too wide, not a quiet fight.
    dropped: u32,
    frames_run: u32,

    pub fn deinit(self: *KillPass, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        self.* = undefined;
    }
};

pub fn writeKillsLua(w: *std.Io.Writer, rec: Recording, first: usize, last: usize, offset: usize) !void {
    if (last <= first) return Error.BadStretch;
    const end = @min(last + offset, rec.frames());
    try w.print(
        \\-- Generated by src/gb_trace.zig's kill pass. Do not edit.
        \\
        \\local STATE =
    , .{});
    try writeLuaBytes(w, rec.state);
    try w.print("\nlocal IN = ", .{});
    try writeLuaBytes(w, rec.inputs[0..end]);
    try w.print("\n\nlocal WATCH = {{", .{});
    for (kill_watch) |a| try w.print("0x{X:0>4},", .{a});
    try w.print("}}\nlocal CARRY = {{", .{});
    for (kill_carry) |a| try w.print("0x{X:0>4},", .{a});
    try w.print("}}\nlocal FIELDS = {{", .{});
    for (kill_slot_fields) |o| try w.print("{d},", .{o});
    try w.print("}}\nlocal WFIELDS = {{", .{});
    for (kill_slot_watched) |o| try w.print("{d},", .{o});
    try w.print("}}\nlocal AIS = {{", .{});
    for (kill_ais) |a| try w.print("[0x{X:0>4}]=true,", .{a});
    try w.print(
        \\}}
        \\local AT, RB, HDR, MAXN, FIRST, LAST = {d}, {d}, {d}, {d}, {d}, {d}
        \\
    , .{ header_at, kill_record_bytes, header_bytes, max_kill_records, first + offset, end });
    try writeDriver(w, offset);
    try w.print(
        \\local prev, dropped = nil, 0
        \\
        \\local function snapshot()
        \\  local s = {{ slot = 0xFF, w = {{}}, c = {{}}, fl = {{}} }}
        \\  for i = 1, #WATCH do s.w[i] = read(WATCH[i], mem) end
        \\  for i = 1, #CARRY do s.c[i] = read(CARRY[i], mem) end
        \\  for k = 0, 15 do
        \\    local base = 0xC600 + k * 32
        \\    local ai = read(base + 0x1E, mem) + read(base + 0x1F, mem) * 256
        \\    -- Not a child: the Gamma's bolt runs the Gamma's AI, and its flag is
        \\    -- a link, whose low nibble is zero (1.0 Step 14); the Zeta's husk and
        \\    -- fireball run the Zeta's, flagged $03 and $06 (1.0 Step 15), and the
        \\    -- Omega's fireball its own, flagged $06 (1.0 Step 16).
        \\    local f = read(base + 0x1C, mem)
        \\    local child = (f & 0x0F) == 0 or f == 0x03 or f == 0x06
        \\    if read(base, mem) ~= 0xFF and AIS[ai] and not child then s.slot = k; break end
        \\  end
        \\  for i = 1, #FIELDS do
        \\    s.fl[i] = s.slot == 0xFF and 0xFF or read(0xC600 + s.slot * 32 + FIELDS[i], mem)
        \\  end
        \\  return s
        \\end
        \\
        \\local function differs(a, b)
        \\  if b == nil or a.slot ~= b.slot then return true end
        \\  for i = 1, #WATCH do if a.w[i] ~= b.w[i] then return true end end
        \\  for i = 1, #FIELDS do
        \\    for j = 1, #WFIELDS do
        \\      if FIELDS[i] == WFIELDS[j] and a.fl[i] ~= b.fl[i] then return true end
        \\    end
        \\  end
        \\  return false
        \\end
        \\
        \\local function finish()
        \\  done = true
        \\  write(AT + 0, 71, sram); write(AT + 1, 66, sram)
        \\  write(AT + 2, 75, sram); write(AT + 3, 49, sram)
        \\  put(AT + 4, wrote, 4)
        \\  put(AT + 8, f, 4)
        \\  put(AT + 12, dropped, 4)
        \\  emu.stop(0)
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  if f >= FIRST then
        \\    local s = snapshot()
        \\    if differs(s, prev) then
        \\      if wrote < MAXN then
        \\        local at = AT + HDR + wrote * RB
        \\        at = put(at, f - OFFSET, 4)
        \\        at = put(at, s.slot, 1)
        \\        for i = 1, #WATCH do at = put(at, s.w[i], 1) end
        \\        for i = 1, #CARRY do at = put(at, s.c[i], 1) end
        \\        for i = 1, #FIELDS do at = put(at, s.fl[i], 1) end
        \\        wrote = wrote + 1
        \\      else
        \\        dropped = dropped + 1
        \\      end
        \\    end
        \\    prev = s
        \\  end
        \\  f = f + 1
        \\  if f >= LAST then finish() end
        \\end, emu.eventType.endFrame)
        \\
    , .{});
}

/// Every frame in `first..last` on which the fight's state moved.
pub fn runKills(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    first: usize,
    last: usize,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
) !KillPass {
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeKillsLua(&lua.writer, rec, first, last, offset);

    var code: u8 = 255;
    const bytes = try spawnPass(allocator, io, rom, rec, lua.written(), last + offset, mesen_path, home, &code);
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[header_at..][0..4], &kills_magic)) return Error.DidNotRun;
    const wrote = std.mem.readInt(u32, bytes[header_at + 4 ..][0..4], .little);
    if (wrote > max_kill_records) return Error.ShortSaveFile;

    const events = try allocator.alloc(KillEvent, wrote);
    for (events, 0..) |*e, i| {
        const at = records_at + i * kill_record_bytes;
        var p = at + 5;
        e.* = .{
            .frame = std.mem.readInt(u32, bytes[at..][0..4], .little),
            .slot = bytes[at + 4],
            .watch = bytes[p..][0..kill_watch.len].*,
            .carry = bytes[p + kill_watch.len ..][0..kill_carry.len].*,
            .fields = undefined,
        };
        p += kill_watch.len + kill_carry.len;
        e.fields = bytes[p..][0..kill_slot_fields.len].*;
    }
    return .{
        .events = events,
        .frames_run = std.mem.readInt(u32, bytes[header_at + 8 ..][0..4], .little),
        .dropped = std.mem.readInt(u32, bytes[header_at + 12 ..][0..4], .little),
    };
}

// ---- The save pass --------------------------------------------------------
//
// Step 15a. Across `first..last`, one record whenever the save path's state
// moves: the game mode (`$09` is the save, `$05`-`$07` the death, `$0C` the
// load), the station's contact flag, whether the "COMPLETED" cooldown is
// running, the death flag, the load flag and the slot. The cooldown itself
// counts down 255 frames a save, so only its being nonzero is watched and the
// value is carried. Every record also carries the active slot's record as it
// sits in cart RAM, so the frame the writer ran is the first record whose
// slot bytes differ from the one before -- and the bytes are the game's own,
// for `save.fields` to be graded against.

/// Watched: a change in any of these writes a record.
pub const save_watch = [_]u16{
    0xFF9B, // gameMode
    0xD07D, // saveContactFlag
    0xD063, // deathFlag
    0xD079, // loadingFromFile
    0xD0A3, // activeSaveSlot
};
/// Carried: read on a recorded frame, never a reason to record one.
pub const save_carry = [_]u16{
    0xD088, // saveMessageCooldownTimer
    0xFF97, // frameCounter
    0xFF81, // hInputRisingEdge
    0xD020, // samusPose
    0xD811, // the map bank
    0xFFC1, // hSamusYScreen
    0xFFC0, // hSamusYPixel
    0xFFC3, // hSamusXScreen
    0xFFC2, // hSamusXPixel
    0xD051, // samusCurHealthLow
    0xD052, // samusCurHealthHigh
    0xD084, // samusDispHealthLow
    0xD085, // samusDispHealthHigh
    0xD089, // metroidCountReal
    0xD09A, // metroidCountDisplayed
    0xD066, // countdownTimerLow
    0xD067, // countdownTimerHigh
    0xD059, // deathAnimTimer
};
/// The slot's first $2E bytes: the magic and `save.fields`.
pub const save_slot_bytes: usize = 0x2E;
/// Frame, the cooldown-running flag, then the three byte lists.
pub const save_record_bytes: usize = 4 + 1 + save_watch.len + save_carry.len + save_slot_bytes;
pub const max_save_records: usize = (sram_bytes - records_at) / save_record_bytes;
pub const saves_magic = [4]u8{ 'G', 'B', 'S', '1' };

pub const SaveEvent = struct {
    frame: u32,
    cooling: u8,
    watch: [save_watch.len]u8,
    carry: [save_carry.len]u8,
    slot: [save_slot_bytes]u8,

    pub fn get(self: SaveEvent, addr: u16) u8 {
        for (save_watch, 0..) |a, i| if (a == addr) return self.watch[i];
        for (save_carry, 0..) |a, i| if (a == addr) return self.carry[i];
        unreachable;
    }
};

pub const SavePass = struct {
    events: []SaveEvent,
    dropped: u32,
    frames_run: u32,

    pub fn deinit(self: *SavePass, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        self.* = undefined;
    }
};

pub fn writeSavesLua(w: *std.Io.Writer, rec: Recording, first: usize, last: usize, offset: usize) !void {
    if (last <= first) return Error.BadStretch;
    const end = @min(last + offset, rec.frames());
    try w.print(
        \\-- Generated by src/gb_trace.zig's save pass. Do not edit.
        \\
        \\local STATE =
    , .{});
    try writeLuaBytes(w, rec.state);
    try w.print("\nlocal IN = ", .{});
    try writeLuaBytes(w, rec.inputs[0..end]);
    try w.print("\n\nlocal WATCH = {{", .{});
    for (save_watch) |a| try w.print("0x{X:0>4},", .{a});
    try w.print("}}\nlocal CARRY = {{", .{});
    for (save_carry) |a| try w.print("0x{X:0>4},", .{a});
    try w.print(
        \\}}
        \\local AT, RB, HDR, MAXN, FIRST, LAST, SLOTN = {d}, {d}, {d}, {d}, {d}, {d}, {d}
        \\
    , .{ header_at, save_record_bytes, header_bytes, max_save_records, first + offset, end, save_slot_bytes });
    try writeDriver(w, offset);
    try w.print(
        \\local prev, dropped = nil, 0
        \\
        \\local function snapshot()
        \\  local s = {{ w = {{}}, c = {{}}, sl = {{}} }}
        \\  for i = 1, #WATCH do s.w[i] = read(WATCH[i], mem) end
        \\  for i = 1, #CARRY do s.c[i] = read(CARRY[i], mem) end
        \\  s.cool = read(0xD088, mem) ~= 0 and 1 or 0
        \\  local base = (read(0xD0A3, mem) & 3) * 64
        \\  local digest = 0
        \\  for i = 0, SLOTN - 1 do
        \\    s.sl[i + 1] = read(base + i, sram)
        \\    digest = (digest * 31 + s.sl[i + 1]) & 0xFFFFFFFF
        \\  end
        \\  s.digest = digest
        \\  return s
        \\end
        \\
        \\local function differs(a, b)
        \\  if b == nil or a.cool ~= b.cool or a.digest ~= b.digest then return true end
        \\  for i = 1, #WATCH do if a.w[i] ~= b.w[i] then return true end end
        \\  return false
        \\end
        \\
        \\local function finish()
        \\  done = true
        \\  write(AT + 0, 71, sram); write(AT + 1, 66, sram)
        \\  write(AT + 2, 83, sram); write(AT + 3, 49, sram)
        \\  put(AT + 4, wrote, 4)
        \\  put(AT + 8, f, 4)
        \\  put(AT + 12, dropped, 4)
        \\  emu.stop(0)
        \\end
        \\
        \\emu.addEventCallback(function()
        \\  if not loaded or done then return end
        \\  if f >= FIRST then
        \\    local s = snapshot()
        \\    if differs(s, prev) then
        \\      if wrote < MAXN then
        \\        local at = AT + HDR + wrote * RB
        \\        at = put(at, f - OFFSET, 4)
        \\        at = put(at, s.cool, 1)
        \\        for i = 1, #WATCH do at = put(at, s.w[i], 1) end
        \\        for i = 1, #CARRY do at = put(at, s.c[i], 1) end
        \\        for i = 1, SLOTN do at = put(at, s.sl[i], 1) end
        \\        wrote = wrote + 1
        \\      else
        \\        dropped = dropped + 1
        \\      end
        \\    end
        \\    prev = s
        \\  end
        \\  f = f + 1
        \\  if f >= LAST then finish() end
        \\end, emu.eventType.endFrame)
        \\
    , .{});
}

/// Every frame in `first..last` on which the save path's state moved.
pub fn runSaves(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    first: usize,
    last: usize,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
) !SavePass {
    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeSavesLua(&lua.writer, rec, first, last, offset);

    var code: u8 = 255;
    const bytes = try spawnPass(allocator, io, rom, rec, lua.written(), last + offset, mesen_path, home, &code);
    defer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[header_at..][0..4], &saves_magic)) return Error.DidNotRun;
    const wrote = std.mem.readInt(u32, bytes[header_at + 4 ..][0..4], .little);
    if (wrote > max_save_records) return Error.ShortSaveFile;

    const events = try allocator.alloc(SaveEvent, wrote);
    for (events, 0..) |*e, i| {
        const at = records_at + i * save_record_bytes;
        var p = at + 5;
        e.* = .{
            .frame = std.mem.readInt(u32, bytes[at..][0..4], .little),
            .cooling = bytes[at + 4],
            .watch = bytes[p..][0..save_watch.len].*,
            .carry = undefined,
            .slot = undefined,
        };
        p += save_watch.len;
        e.carry = bytes[p..][0..save_carry.len].*;
        p += save_carry.len;
        e.slot = bytes[p..][0..save_slot_bytes].*;
    }
    return .{
        .events = events,
        .frames_run = std.mem.readInt(u32, bytes[header_at + 8 ..][0..4], .little),
        .dropped = std.mem.readInt(u32, bytes[header_at + 12 ..][0..4], .little),
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    rec: Recording,
    first: usize,
    count: usize,
    stride: usize,
    offset: usize,
    mesen_path: []const u8,
    home: []const u8,
    lane: ?u8,
) !Pass {
    if (count > max_frames) return Error.TooManyFrames;

    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeLua(&lua.writer, rec, first, count, stride, offset);

    const last = @min(first + offset + count * stride, rec.frames() + offset);
    var code: u8 = 255;
    const bytes = try spawnPassIn(allocator, io, rom, rec, lua.written(), last, mesen_path, home, &code, lane);
    errdefer allocator.free(bytes);
    if (!std.mem.eql(u8, bytes[header_at..][0..4], &magic)) return Error.DidNotRun;

    const wrote = std.mem.readInt(u32, bytes[header_at + 8 ..][0..4], .little);
    if (records_at + wrote * record_bytes > sram_bytes) return Error.ShortSaveFile;

    var head: [seam_frames]u32 = undefined;
    var tail: [seam_frames]u32 = undefined;
    for (0..seam_frames) |i| {
        head[i] = std.mem.readInt(u32, bytes[header_at + seam_at + 4 * i ..][0..4], .little);
        tail[i] = std.mem.readInt(u32, bytes[header_at + seam_at + 4 * (seam_frames + i) ..][0..4], .little);
    }

    var beam_log: ?[]const BeamChange = null;
    var beam_dropped: usize = 0;
    const log_at = beamLogAt(count);
    if (log_at != 0) {
        const n: usize = bytes[log_at];
        const kept = @min(n, beam_log_entries);
        beam_dropped = n - kept;
        const log = try allocator.alloc(BeamChange, kept);
        for (log, 0..) |*c, i| {
            const e = bytes[log_at + 1 + 4 * i ..][0..4];
            c.* = .{ .frame = std.mem.readInt(u24, e[0..3], .little), .beam = e[3] };
        }
        beam_log = log;
    }

    return .{
        .beam_log = beam_log,
        .beam_dropped = beam_dropped,
        .head = head,
        .tail = tail,
        .end_beam = bytes[header_at + end_at],
        .end_clock = std.mem.readInt(u16, bytes[header_at + end_at + 1 ..][0..2], .little),
        .first = std.mem.readInt(u32, bytes[header_at + 4 ..][0..4], .little),
        .stride = std.mem.readInt(u32, bytes[header_at + 22 ..][0..4], .little),
        .offset = std.mem.readInt(u16, bytes[header_at + 26 ..][0..2], .little),
        .frames = wrote,
        .frames_run = std.mem.readInt(u32, bytes[header_at + 12 ..][0..4], .little),
        .polls = std.mem.readInt(u32, bytes[header_at + 16 ..][0..4], .little),
        .code = code,
        .rows = bytes[records_at..][0 .. wrote * record_bytes],
        .game_save = bytes[0..game_sram_bytes],
        .backing = bytes,
    };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "the record covers itself exactly and a pass fits in one save file" {
    var seen: [record_bytes]bool = @splat(false);
    var n: usize = 0;
    inline for (fields) |f| {
        const off = offsetOf(f.name);
        try testing.expectEqual(n, off);
        for (0..f.width) |k| {
            try testing.expect(!seen[off + k]);
            seen[off + k] = true;
        }
        n += f.width;
    }
    try testing.expectEqual(record_bytes, n);
    for (seen) |s| try testing.expect(s);

    // And the region arithmetic: records start above the game's own save bank,
    // so a pass can watch the recording save without overwriting what it wrote.
    try testing.expect(records_at >= game_sram_bytes);
    try testing.expect(records_at + max_frames * record_bytes <= sram_bytes);
    try testing.expect(records_at + (max_frames + 1) * record_bytes > sram_bytes);
}

test "stamping the RAM size leaves a header the boot ROM's checksum accepts" {
    var rom = [_]u8{0x5A} ** 0x200;
    stampRam(&rom);
    try testing.expectEqual(ram_size_byte, rom[ram_size_addr]);
    var sum: u8 = 0;
    for (rom[header_first .. header_last + 1]) |b| sum = sum -% b -% 1;
    try testing.expectEqual(rom[header_checksum], sum);

    // Two bytes and no more: the cartridge type is deliberately not touched,
    // because swapping the memory-bank controller under a running replay is
    // not worth the extra banks it would buy.
    var before = [_]u8{0x5A} ** 0x200;
    var differ: usize = 0;
    for (before[0..], rom[0..]) |*a, b| {
        if (a.* != b) differ += 1;
    }
    try testing.expectEqual(@as(usize, 2), differ);
    try testing.expectEqual(@as(u8, 0x5A), before[0x147]);
}

test "an input row parses into the same byte order the VBM path produces" {
    const text =
        "|..|........\n" ++
        "|..|....S...\n" ++
        "|..|UDLRSsBA\n" ++
        "|..|..L....A\n";
    const rows = try parseInputs(testing.allocator, text);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqual(@as(u8, 0), rows[0]);
    try testing.expectEqual(tas.held_start, rows[1]);
    try testing.expectEqual(@as(u8, 0xFF), rows[2]);
    try testing.expectEqual(tas.held_left | tas.held_a, rows[3]);
}

test "a row that is not a row is refused rather than read as no buttons" {
    try testing.expectError(Error.BadInputRow, parseInputs(testing.allocator, "MesenMovie 3\n"));
    try testing.expectError(Error.BadInputRow, parseInputs(testing.allocator, "|..|...X....\n"));
    try testing.expectError(Error.NoInputRows, parseInputs(testing.allocator, "\n\n"));
}

/// A one-entry zip with the payload stored rather than deflated, which is the
/// half of the reader that can be exercised without a compressor.
fn storedZip(buf: []u8, name: []const u8, data: []const u8) []u8 {
    var n: usize = 0;
    const local = n;
    @memcpy(buf[n..][0..4], &std.zip.local_file_header_sig);
    @memset(buf[n + 4 ..][0..22], 0);
    std.mem.writeInt(u32, buf[n + 18 ..][0..4], @intCast(data.len), .little);
    std.mem.writeInt(u32, buf[n + 22 ..][0..4], @intCast(data.len), .little);
    std.mem.writeInt(u16, buf[n + 26 ..][0..2], @intCast(name.len), .little);
    std.mem.writeInt(u16, buf[n + 28 ..][0..2], 0, .little);
    n += 30;
    @memcpy(buf[n..][0..name.len], name);
    n += name.len;
    @memcpy(buf[n..][0..data.len], data);
    n += data.len;

    const central = n;
    @memcpy(buf[n..][0..4], &std.zip.central_file_header_sig);
    @memset(buf[n + 4 ..][0..42], 0);
    std.mem.writeInt(u32, buf[n + 20 ..][0..4], @intCast(data.len), .little);
    std.mem.writeInt(u32, buf[n + 24 ..][0..4], @intCast(data.len), .little);
    std.mem.writeInt(u16, buf[n + 28 ..][0..2], @intCast(name.len), .little);
    std.mem.writeInt(u32, buf[n + 42 ..][0..4], @intCast(local), .little);
    n += 46;
    @memcpy(buf[n..][0..name.len], name);
    n += name.len;

    const end = n;
    @memcpy(buf[n..][0..4], &std.zip.end_record_sig);
    @memset(buf[n + 4 ..][0..18], 0);
    std.mem.writeInt(u16, buf[n + 8 ..][0..2], 1, .little);
    std.mem.writeInt(u16, buf[n + 10 ..][0..2], 1, .little);
    std.mem.writeInt(u32, buf[n + 12 ..][0..4], @intCast(end - central), .little);
    std.mem.writeInt(u32, buf[n + 16 ..][0..4], @intCast(central), .little);
    n += 22;
    return buf[0..n];
}

test "the zip reader finds an entry by name and refuses one that is not there" {
    var buf: [256]u8 = undefined;
    const zip = storedZip(&buf, "Input.txt", "|..|....S...\n");
    const got = try zipEntry(testing.allocator, zip, "Input.txt");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("|..|....S...\n", got);
    try testing.expectError(Error.NoSuchEntry, zipEntry(testing.allocator, zip, "SaveState.mss"));
}

test "the recording names the cartridge, and a different cartridge is refused" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const mmo = std.Io.Dir.cwd().readFileAlloc(testing.io, "reference/metroid2.mmo", testing.allocator, .limited(64 << 20)) catch
        return error.SkipZigTest;
    defer testing.allocator.free(mmo);

    var rec = try readRecording(testing.allocator, mmo);
    defer rec.deinit(testing.allocator);

    // The whole recording, and the three files it is made of.
    try testing.expectEqual(@as(usize, 76951), rec.frames());
    try testing.expect(rec.state.len > 0);
    try testing.expectEqualStrings("MSS", rec.state[0..3]);
    try testing.expectEqualStrings("metroid2.gb", rec.gameFile().?);

    // A `.mmo` carries the cartridge's whole SHA-1, which is a stronger check
    // than the title and two checksums `tas.parse` has to make do with.
    try rec.checkCartridge(rom);
    const other = try testing.allocator.dupe(u8, rom);
    defer testing.allocator.free(other);
    other[0x4000] ^= 0xFF;
    try testing.expectError(Error.WrongCartridge, rec.checkCartridge(other));
}

test "the generated script drives the movie's own bytes at the movie's own index" {
    const mmo = std.Io.Dir.cwd().readFileAlloc(testing.io, "reference/metroid2_par01.mmo", testing.allocator, .limited(64 << 20)) catch
        return error.SkipZigTest;
    defer testing.allocator.free(mmo);
    var rec = try readRecording(testing.allocator, mmo);
    defer rec.deinit(testing.allocator);

    var lua: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lua.deinit();
    try writeLua(&lua.writer, rec, 100, 8, 1, input_offset);
    const src = lua.written();

    // The index, which is the thing that was wrong for a day.
    try testing.expect(std.mem.indexOf(u8, src, "string.byte(IN, f + 1 - OFFSET)") != null);
    // The savestate contract: loaded from an exec callback, not an event one.
    try testing.expect(std.mem.indexOf(u8, src, "emu.loadSavestate(STATE)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "emu.callbackType.exec, 0x0040") != null);
    // And the window it was asked for. `OFFSET` is the shared driver's, so it
    // is asserted separately -- both scripts get it from the same emitter.
    try testing.expect(std.mem.indexOf(u8, src, "local FIRST, COUNT, STRIDE = 101, 8, 1") != null);
    try testing.expect(std.mem.indexOf(u8, src, "local OFFSET = 1") != null);
    // And it stops after the last of them. FIRST is offset and the stop must
    // be too: at `f >= 108` the pass wrote 7 rows of 8, and `census` reads a
    // short pass as the movie running out, so every window over one pass was
    // silently cut to its first.
    // The stop is the window's end and nothing else: a pass plays to it after
    // its last row, for the tail digests and the end state.
    try testing.expect(std.mem.indexOf(u8, src, "local SEAM, SEAM_AT, STOP = 4, 28, 109") != null);
    try testing.expect(std.mem.indexOf(u8, src, "if f >= STOP then finish()") != null);
    // Lua's modulo, not a format escape. Zig's multiline strings are raw, so a
    // `%%` carried over from the throwaway Python harness this grew out of
    // reaches the emulator verbatim and the script dies silently -- which is
    // what a testrunner run does with a script error, and it cost an hour.
    try testing.expect(std.mem.indexOf(u8, src, "% STRIDE == 0") != null);
    try testing.expect(std.mem.indexOf(u8, src, "%%") == null);

    // A window wider than one save file is refused rather than truncated.
    try testing.expectError(Error.TooManyFrames, writeLua(&lua.writer, rec, 0, max_frames + 1, 1, input_offset));
}

test "a window that opens on a stale pad byte is aligned, not desynced" {
    // The recording's second census pass, in miniature: Right held until the
    // window's first frame and released on it, and `$FF80` still holding Right
    // there because the joypad routine has not run yet. The first row has no
    // row before it, so it cannot be a change, and it is not evidence.
    const inputs = [_]u8{ 0x10, 0x10, 0x00, 0x00, 0x01, 0x01, 0x00, 0x20, 0x20, 0x00, 0x80, 0x00 };
    // Frames 2..11: the movie's own bytes, but for the first.
    const pads = [_]u8{ 0x10, 0x00, 0x01, 0x01, 0x00, 0x20, 0x20, 0x00, 0x80, 0x00 };
    var rows: [pads.len * record_bytes]u8 = @splat(0);
    for (pads, 0..) |p, i| rows[i * record_bytes + offsetOf("pad")] = p;
    const rec: Recording = .{ .inputs = &inputs, .state = &.{}, .settings = &.{} };
    const pass: Pass = .{
        .first = 2,
        .stride = 1,
        .offset = 1,
        .frames = pads.len,
        .frames_run = 0,
        .polls = 0,
        .code = 0,
        .rows = &rows,
        .game_save = &.{},
        .backing = &.{},
    };
    try testing.expectEqual(@as(?usize, 0), pass.lag(rec));
    try testing.expectEqual(@as(usize, 7), pass.padChanges());
    try testing.expect(pass.padChanges() >= min_changed);

    // And a real desync is still one: the same window with a press the movie
    // does not have.
    var bad = rows;
    bad[4 * record_bytes + offsetOf("pad")] = 0x02;
    var desynced = pass;
    desynced.rows = &bad;
    try testing.expectEqual(@as(?usize, null), desynced.lag(rec));
}

test "the beam log fits after a window that leaves room, and never over one" {
    try testing.expect(beamLogAt(max_frames) == 0);
    try testing.expect(beamLogAt(max_frames - beam_log_rows) != 0);
    try testing.expect(records_at + (max_frames - beam_log_rows) * record_bytes <= beamLogAt(max_frames - beam_log_rows));
    try testing.expectEqual(sram_bytes, beamLogAt(1) + beam_log_bytes);
}

test "a seam is exact when one tail frame is one head frame, a gap when none is" {
    try testing.expectEqual(Seam{ .exact = .{ .at_tail = 3, .at_head = 0 } }, seam(.{ 1, 2, 3, 4 }, .{ 4, 5, 6, 7 }));
    // Three frames apart is the widest a match can be.
    try testing.expectEqual(Seam{ .exact = .{ .at_tail = 0, .at_head = 3 } }, seam(.{ 1, 2, 3, 4 }, .{ 9, 8, 7, 1 }));
    // A machine standing still repeats a digest; the join is its last frame.
    try testing.expectEqual(Seam{ .exact = .{ .at_tail = 3, .at_head = 0 } }, seam(.{ 5, 5, 5, 5 }, .{ 5, 6, 7, 8 }));
    try testing.expectEqual(Seam.gap, seam(.{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }));
    try testing.expectEqual(Seam.unchecked, seam(.{ 1, 2, 3, 0 }, .{ 3, 6, 7, 8 }));
}

test "the emitted row records every column the record declares, and no other" {
    var lua: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lua.deinit();
    try writeRow(&lua.writer);
    const src = lua.written();

    // One store per column, in the record's own order -- which is what makes
    // `Pass.get`'s offsets mean anything.
    var stores: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, "at = put(at, ")) |i| : (at = i + 1) stores += 1;
    try testing.expectEqual(fields.len, stores);

    // And every address is actually read. A column declared and not recorded
    // would leave its bytes holding the previous frame's, which reads as a
    // value that simply never changes -- the quietest way for this to be
    // wrong, and the reason the row is generated rather than transcribed.
    inline for (fields) |f| {
        if (f.kind != .mem) continue;
        for (0..f.width) |k| {
            var want: [24]u8 = undefined;
            const s = try std.fmt.bufPrint(&want, "read(0x{X:0>4}, mem)", .{f.addr + k});
            try testing.expect(std.mem.indexOf(u8, src, s) != null);
        }
    }

    // The pickups, by name, because Step 11 is what they are for.
    try testing.expect(std.mem.indexOf(u8, src, "read(0xD045, mem)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "read(0xD050, mem)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "read(0xD082, mem) * 256 + read(0xD081, mem)") != null);
}

test "the record carries everything a graded stretch reads" {
    // Named rather than counted, so adding a column does not have to touch
    // this and removing one cannot pass quietly.
    //
    // The first group is `tas.Sample`'s, which is what `Pass.samples` builds
    // and every trace reader consumes. The second is `oracle.Frame`'s -- what a
    // stretch of the anchored sweep is graded through. The third is this
    // file's own: the pad byte that checks the input alignment, the pickups
    // Step 11 needs, and the two block columns that say whether an anchor
    // needs a world pass at all.
    const sample_columns = [_][]const u8{
        "input",    "samus_y",  "samus_x", "camera_y",
        "camera_x", "pose",     "map_bank", "metroid_count",
        "wram_digest",
    };
    const frame_columns = [_][]const u8{ "facing", "counter", "water", "pad" };
    const own_columns = [_][]const u8{
        "items", "etanks", "missiles_max", "live_blocks", "blocks_seen",
    };

    inline for (sample_columns ++ frame_columns ++ own_columns) |name| {
        _ = offsetOf(name); // @compileError names the missing column
    }
    // And nothing else, so a column added without a purpose is noticed here
    // rather than costing every pass its width forever.
    try testing.expectEqual(
        sample_columns.len + frame_columns.len + own_columns.len,
        fields.len,
    );
}

test "a world pass fits its region, and the two kinds of pass cannot be confused" {
    // 1 280 bytes of world plus an 8-byte header against the 24 512 the trace
    // region holds. The budget is why this is a mode and not four more columns.
    try testing.expectEqual(@as(usize, 1024 + 256 + 8), world_bytes);
    try testing.expect(records_at + max_worlds * world_bytes <= sram_bytes);
    try testing.expect(records_at + (max_worlds + 1) * world_bytes > sram_bytes);

    // Same offset, same length, different bytes: a row pass read back as a
    // world pass -- or the reverse -- is the failure this prevents, and both
    // read-backs check the magic before they touch anything else.
    try testing.expectEqual(magic.len, world_magic.len);
    try testing.expect(!std.mem.eql(u8, &magic, &world_magic));

    // The block array is the sixteen slots M2RoS documents, not a round number
    // that happens to divide.
    try testing.expectEqual(@as(usize, 16), block_slots);
    try testing.expectEqual(@as(usize, 16), block_slot_bytes);
}

test "the AI census hooks the one instruction every enemy AI is dispatched through" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);

    // `LD BC,$FFF2 / LD A,(BC) / LD H,A / DEC C / LD A,(BC) / LD L,A / JP (HL)`,
    // ending on the hooked address in bank 2 -- so HL is `hEnemy.pAI`, the two
    // bytes the script reads, and not something it has to reconstruct.
    const at = ai_jump_bank * 0x4000 + (ai_jump_addr - 0x4000);
    const want = [_]u8{ 0x01, 0xF2, 0xFF, 0x0A, 0x67, 0x0D, 0x0A, 0x6F, 0xE9 };
    try testing.expectEqualSlices(u8, &want, rom[at + 1 - want.len .. at + 1]);
    try testing.expectEqual(ai_pointer_addr + 1, 0xFFF2);

    // The script's bank test is "is JP (HL) under the PC". It is only a bank
    // test if no other bank has that opcode at that address.
    var banks: usize = 0;
    var b: usize = 0;
    while (b * 0x4000 < rom.len) : (b += 1) {
        if (b == 0) continue;
        if (rom[b * 0x4000 + (ai_jump_addr - 0x4000)] == 0xE9) banks += 1;
    }
    try testing.expectEqual(@as(usize, 1), banks);

    // The records and the counts after them both fit the region.
    try testing.expect(records_at + max_ai_seen * (ai_seen_bytes + 4) <= sram_bytes);
    try testing.expect(!std.mem.eql(u8, &ais_magic, &magic));
    try testing.expect(!std.mem.eql(u8, &ais_magic, &world_magic));
    try testing.expect(!std.mem.eql(u8, &ais_magic, &refs_magic));

    const mmo = std.Io.Dir.cwd().readFileAlloc(testing.io, "reference/metroid2_par01.mmo", testing.allocator, .limited(64 << 20)) catch
        return error.SkipZigTest;
    defer testing.allocator.free(mmo);
    var rec = try readRecording(testing.allocator, mmo);
    defer rec.deinit(testing.allocator);

    var lua: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lua.deinit();
    try writeAiLua(&lua.writer, rec, 500, input_offset);
    const src = lua.written();
    try testing.expect(std.mem.indexOf(u8, src, "emu.callbackType.exec, 0x5650, 0x5650") != null);
    try testing.expect(std.mem.indexOf(u8, src, "read(0x5650, mem) ~= 0xE9") != null);
    try testing.expect(std.mem.indexOf(u8, src, "read(0xFFF1, mem) + read(0xFFF2, mem) * 256") != null);
    try testing.expect(std.mem.indexOf(u8, src, "emu.setInput(B[m], 0)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "%%") == null);
    try testing.expectError(Error.TooManyFrames, writeAiLua(&lua.writer, rec, 0, input_offset));
}

test "the world script asks for the frames it was given, through the ungated memory type" {
    const mmo = std.Io.Dir.cwd().readFileAlloc(testing.io, "reference/metroid2_par01.mmo", testing.allocator, .limited(64 << 20)) catch
        return error.SkipZigTest;
    defer testing.allocator.free(mmo);
    var rec = try readRecording(testing.allocator, mmo);
    defer rec.deinit(testing.allocator);

    var lua: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lua.deinit();
    try writeWorldLua(&lua.writer, rec, &.{ 100, 250 }, input_offset);
    const src = lua.written();

    // Wanted frames are keyed by *emulator* frame, which is the movie frame
    // plus the offset. Keying them by the movie frame would sample a frame
    // early, which is the defect this whole file is built around not repeating.
    try testing.expect(std.mem.indexOf(u8, src, "local WANT = {[101]=0,[251]=1,}") != null);

    // The video-RAM path, and the bus fallback behind it. $9800 through the
    // CPU bus reads as $FF during mode 3, so a script that only had the
    // fallback would sometimes record a blank room and call it a room.
    try testing.expect(std.mem.indexOf(u8, src, "local vram = emu.memType.gbVideoRam") != null);
    try testing.expect(std.mem.indexOf(u8, src, "read(0x1800 + i, vram)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "read(0x9800 + i, mem)") != null);
    // And the block array beside it.
    try testing.expect(std.mem.indexOf(u8, src, "read(0xD900 + i, mem)") != null);

    // The shared driver, so the world pass cannot quietly drift from the row
    // pass's input delivery.
    try testing.expect(std.mem.indexOf(u8, src, "emu.setInput(B[m], 0)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "emu.callbackType.exec, 0x0040") != null);
    try testing.expect(std.mem.indexOf(u8, src, "%%") == null);

    // More anchors than one save file holds is refused rather than truncated,
    // and so is none.
    const too_many = try testing.allocator.alloc(u32, max_worlds + 1);
    defer testing.allocator.free(too_many);
    @memset(too_many, 0);
    try testing.expectError(Error.TooManyFrames, writeWorldLua(&lua.writer, rec, too_many, input_offset));
    try testing.expectError(Error.TooManyFrames, writeWorldLua(&lua.writer, rec, &.{}, input_offset));
}

test "a blank world is recognised as a blocked read rather than a room" {
    var w: World = .{
        .frame = 0,
        .scx = 0,
        .scy = 0,
        .via = .cpu_bus,
        .tiles = @splat(0xFF),
        .blocks = @splat(0),
    };
    // The failure mode this exists for: a blocked VRAM read succeeds, returns
    // 1 024 identical bytes, and every comparison downstream then agrees that
    // both machines are in the same nothing.
    try testing.expect(w.blank());
    try testing.expectEqual(@as(usize, 0), w.liveBlocks());

    w.tiles[512] = 0x2A;
    try testing.expect(!w.blank());

    // A slot's first byte is its frame counter, and zero is the game's own
    // "empty" -- so a live slot is one with a nonzero counter, not a nonzero
    // position.
    w.blocks[0 * block_slot_bytes] = 0x10;
    w.blocks[3 * block_slot_bytes] = 0x04;
    w.blocks[3 * block_slot_bytes + 1] = 0x50;
    try testing.expectEqual(@as(usize, 2), w.liveBlocks());
}

test "the recording is vendored, not tracked" {
    // `policy.zig` is the gate that keeps ROM-derived bytes out of the
    // repository, and it skips `reference/`. This asserts that rather than
    // trusting it, because the recording landing in a commit is exactly the
    // failure that check exists for.
    const policy = @import("policy.zig");
    var found = false;
    for (policy.skip_dirs) |d| {
        if (std.mem.eql(u8, d, "reference")) found = true;
    }
    try testing.expect(found);
}

test "an anchored pass fits its region, and the three kinds cannot be confused" {
    // The snapshot is a world plus the 256-byte block-type table plus the
    // twenty-four bytes of header that carry `room.placement` and the camera.
    try testing.expectEqual(@as(usize, 24 + 1024 + 256 + 256), snapshot_bytes);
    try testing.expectEqual(@as(usize, 24512), trace_region);

    // The budget the sweep batches against, computed rather than asserted from
    // a comment: one stretch keeps 850 frames of the region and four keep 676
    // between them. This is why a long stretch is capped by a caller that can
    // say so and not truncated by a script that cannot.
    try testing.expectEqual(@as(usize, 850), refFramesBudget(1));
    try testing.expectEqual(@as(usize, 676), refFramesBudget(4));

    const one = [_]Stretch{.{ .origin = 100, .frames = @intCast(refFramesBudget(1)) }};
    try testing.expect(refsFit(&one));
    const over = [_]Stretch{.{ .origin = 100, .frames = @intCast(refFramesBudget(1) + 1) }};
    try testing.expect(!refsFit(&over));
    try testing.expect(!refsFit(&.{}));

    // Three magics at one offset, all four bytes long: a read-back that
    // guessed would report a room's tiles as a run of frames.
    try testing.expectEqual(magic.len, refs_magic.len);
    try testing.expect(!std.mem.eql(u8, &magic, &refs_magic));
    try testing.expect(!std.mem.eql(u8, &world_magic, &refs_magic));
}

test "the anchored script snapshots the frame before the origin and records from it" {
    const mmo = std.Io.Dir.cwd().readFileAlloc(testing.io, "reference/metroid2_par01.mmo", testing.allocator, .limited(64 << 20)) catch
        return error.SkipZigTest;
    defer testing.allocator.free(mmo);
    var rec = try readRecording(testing.allocator, mmo);
    defer rec.deinit(testing.allocator);

    var lua: std.Io.Writer.Allocating = .init(testing.allocator);
    defer lua.deinit();
    const stretches = [_]Stretch{
        .{ .origin = 500, .frames = 40 },
        .{ .origin = 900, .frames = 60 },
    };
    try writeRefsLua(&lua.writer, rec, &stretches, input_offset);
    const src = lua.written();

    // **The frame before the origin, in emulator frames.** A boot record is
    // taken from the frame before the reference's frame 0 -- `oracle`'s
    // `MovieCapture` snapshots on `frame + 1 == origin` -- and both numbers
    // here are shifted by the input offset, the way the world pass keys `WANT`.
    try testing.expect(std.mem.indexOf(u8, src, "{snap=500, first=501, count=40, sbase=64, rbase=3184, n=0}") != null);
    // The second stretch's rows start after the first stretch's, which start
    // after both snapshots: 64 + 2*1560 = 3184, then 40 records of 27.
    try testing.expect(std.mem.indexOf(u8, src, "{snap=900, first=901, count=60, sbase=1624, rbase=4264, n=0}") != null);

    // `room.placement`'s six bytes, the camera pair, and the collision
    // threshold -- the fields a `Settled` has that a `World` does not.
    for ([_][]const u8{
        "read(0xD056, mem)", "read(0xD811, mem)", "read(0xD058, mem)",
        "read(0xFFC1, mem)", "read(0xFFC3, mem)", "read(0xFFC0, mem)",
        "read(0xFFC2, mem)", "read(0xFFCA, mem) + read(0xFFCB, mem) * 256",
        "read(0xFFC8, mem) + read(0xFFC9, mem) * 256",
    }) |want| {
        try testing.expect(std.mem.indexOf(u8, src, want) != null);
    }
    // The block-type table beside the tilemap and the block array. Without it
    // two machines walk through the same picture under different rules.
    try testing.expect(std.mem.indexOf(u8, src, "read(0xDC00 + k, mem)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "read(0xD900 + k, mem)") != null);
    // The ungated tilemap read, and the bus behind it.
    try testing.expect(std.mem.indexOf(u8, src, "read(0x1800 + i, vram)") != null);

    // The same driver as every other pass, so input delivery cannot drift
    // between the kinds.
    try testing.expect(std.mem.indexOf(u8, src, "emu.setInput(B[m], 0)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "emu.callbackType.exec, 0x0040") != null);
    // And the same row body, so a stretch's frames are the columns every other
    // track is read as.
    try testing.expect(std.mem.indexOf(u8, src, "read(0xD089, mem)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "%%") == null);

    // A stretch with nothing before it has no frame to snapshot, and a stretch
    // of no frames is a snapshot nobody grades against. Both are refused by
    // name rather than producing a script that records nothing.
    try testing.expectError(Error.BadStretch, writeRefsLua(&lua.writer, rec, &.{.{ .origin = 0, .frames = 10 }}, input_offset));
    try testing.expectError(Error.BadStretch, writeRefsLua(&lua.writer, rec, &.{.{ .origin = 10, .frames = 0 }}, input_offset));
    try testing.expectError(Error.BadStretch, writeRefsLua(&lua.writer, rec, &.{}, input_offset));
    try testing.expectError(Error.TooManyFrames, writeRefsLua(
        &lua.writer,
        rec,
        &.{.{ .origin = 10, .frames = @intCast(refFramesBudget(1) + 1) }},
        input_offset,
    ));
}
