//! Driving the real game with a published tool-assisted run, and recording
//! what it does frame by frame.
//!
//! `01-requirements` (D1) asks for "a reference trace our build is compared
//! against for as far as Phase 0a's logic reaches". This is the Game Boy half
//! of producing one: a VBM parser, and a runner that feeds the movie's inputs
//! into Step 6's emulator and samples the game's own state at every frame
//! boundary.
//!
//! Three things fall out of the same run, which is why they share a file:
//!
//!   1. The reference trace itself — position, camera, pose, map bank, Metroid
//!      count, and a digest of all of WRAM.
//!   2. The loadout addresses Step 14 deferred. That step shipped `room.Spawn`'s
//!      loadout as an unnamed address/value list, with evidence: ninety seconds
//!      of directed play writes exactly one byte of cartridge RAM, because the
//!      game only writes a record at a save station and random input never
//!      reaches one. A TAS reaches one. `room.SaveLog` rides along here.
//!   3. Coverage. Step 14's ledger left 31 772 bytes of banks 0, 2 and 4 that
//!      no run had ever executed. A run that finishes the game executes most of
//!      what a run that wanders a few rooms cannot.
//!
//! ## The movie is checked against the ROM, not assumed to match it
//!
//! A VBM header carries the cartridge's identity: the title at $134, the header
//! checksum at $14D, and the global checksum at $14E read big-endian. All three
//! are compared against the configured ROM before a single frame runs, so
//! pointing this at the Japanese revision fails immediately and by name rather
//! than desyncing forty minutes in and looking like an emulator bug.
//!
//! ## Where a frame ends is a question, not a given
//!
//! A movie is a list of inputs indexed by frame, so replaying one requires
//! agreeing with the recording emulator about when a frame ends. Three answers
//! are defensible and they are not the same answer:
//!
//!   - `.lcd` — a frame ends when the LCD finishes one, at the wrap from line
//!     153 to line 0. This is what the rest of this repository means by a
//!     frame, and `harness.runScript` documents what it costs: **Metroid II
//!     turns the LCD off during a screen transition**, and while it is off no
//!     frame ever ends.
//!   - `.cycles` — a frame is 70 224 cycles, LCD or no LCD, which is what a
//!     recording emulator that must not hang on a blanked screen has to do.
//!   - `.vblank` — a frame ends when LY reaches 144, which is where VBA's own
//!     GB core ends one. Same stall on a blanked screen as `.lcd`, five
//!     scanlines earlier on every other frame.
//!
//! Which one the 2007 VBA build used is not documented anywhere we can cite, so
//! it was measured. `findInputOrigin` asks the first half of the question — at
//! which machine frame does the movie's input first start the game:
//!
//!     frame source   boot ROM   movie frame 0 lands at machine frame
//!     -----------------------------------------------------------
//!     cycles         SameBoy    92
//!     cycles         none        8
//!     lcd            SameBoy    81
//!     lcd            none        1
//!     vblank         SameBoy    80
//!     vblank         none        0
//!
//! So VBA ran no boot ROM — the ~80-frame gap between the two boot columns is
//! the logo — and its counter stopped with the screen, which rules `.cycles`
//! out. It does **not** separate `.lcd` from `.vblank`, because five scanlines
//! is less than a frame and both answer within one.
//!
//! ## The five scanlines are the whole run (measured 2026-08-31)
//!
//! Metroid II reads the joypad inside its VBlank handler, ten reads of $FF00
//! at **LY 149**. Under `.lcd` the replay applies a frame's input at the LY
//! wrap, 1824 cycles *after* that poll — so the poll sits right against the
//! boundary, and the game's frame is not a fixed length, so it drifts across
//! it. Measured on the any% run's first 8000 frames: **713 frames whose poll
//! the boundary cut in half**, the game reading the previous frame's byte on
//! each. A one-frame press is simply lost. The first is at frame 463, where
//! the movie taps A for a single frame and the game never sees it; the replay
//! was walking into a wall 80 frames later.
//!
//! Under `.vblank` the boundary is at LY 144, five lines *before* the poll,
//! and the same 8000 frames misdeliver **nothing**. `delivery` and `pollShape`
//! measure this rather than asserting it, from the game's own $FF80.
//!
//! The origin has one more degree of freedom, and it is also measured: the
//! horizon is periodic in the offset with period 4, because $FF97 — the frame
//! counter the walk speed, the jump arc and the streamer all read — is what
//! the offset shifts. Every offset ≡ 0 (mod 4) puts the any% run's horizon at
//! ~8440 frames and the 100% run's at ~4600; every other residue puts both
//! under 1600. `measured_input_offset` is the smallest such offset that still
//! delivers both movies' Start press.
//!
//! ## What a desync is and is not
//!
//! Our SM83 core is graded against SameBoy (Step 6) but it is not VBA, and a
//! 45-minute TAS is the most timing-sensitive input that exists. A desync is
//! expected somewhere. What changed on 2026-08-31 is that it is no longer
//! *accepted* somewhere: F10 makes the reachable-frame count the progress
//! metric, so the runner reports the horizon as a number — the frame at which
//! the replay stops being the published run — beside the progress markers it
//! observed. The first cause found that way was this file's own frame
//! boundary, which is worth stating plainly: the desync was not in the CPU.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const lcd_mod = @import("gb/lcd.zig");
const room = @import("room.zig");
const ledger = @import("ledger.zig");
const save = @import("save.zig");
const ppu_mod = @import("gb/ppu.zig");
const bus_mod = @import("gb/bus.zig");

pub const Error = error{
    BadSignature,
    UnsupportedVersion,
    StartsFromSavestate,
    StartsFromSram,
    NotGameBoy,
    NoControllerOne,
    Truncated,
    TitleMismatch,
    HeaderChecksumMismatch,
    GlobalChecksumMismatch,
};

// ---- The VBM container ----------------------------------------------------
//
// Field offsets are from the VBM header layout VisualBoyAdvance writes. Each
// one below is stated with what it reads on the two published Metroid II
// movies, so the layout is anchored to observed bytes rather than to memory of
// a header file: `xxd -l 64` on either file shows exactly these values.

const sig = "VBM\x1A";

const off = struct {
    const signature: usize = 0x00;
    const version: usize = 0x04;
    const uid: usize = 0x08;
    /// 162 505 on the any% run; the file holds one input word more than this.
    const frames: usize = 0x0C;
    const rerecords: usize = 0x10;
    /// 0 on both movies: power-on, no savestate, no preloaded SRAM.
    const start_flags: usize = 0x14;
    /// 1 on both: controller 1 only, which is all a Game Boy has.
    const controller_flags: usize = 0x15;
    const type_flags: usize = 0x16;
    /// **$30 on both movies, and this file has never decoded it.** Every other
    /// header field here carries a measured note; this one is read and ignored.
    ///
    /// It was offered as the lead on the desync that ended both replays about
    /// 220 frames after control. It was not the cause -- the cause was this
    /// file's own frame boundary, see the module comment -- and it is left
    /// undecoded and no longer suspected. Both movies agreeing on it says only
    /// that both were recorded with the same emulator settings.
    const options_flags: usize = 0x17;
    /// 3 on both. VBA's enum: 1 CGB, 2 SGB, 3 DMG, 4 GBA, 5 SGB2.
    const gb_emulator_type: usize = 0x20;
    /// "METROID2" then zeroes, the cartridge title at $134.
    const title: usize = 0x24;
    const title_len: usize = 12;
    const minor_version: usize = 0x30;
    /// $97 on both, which is `metroid2.gb`'s header checksum byte at $14D.
    const rom_crc: usize = 0x31;
    /// $581F on both, which is the ROM's global checksum at $14E read
    /// big-endian. Stored here little-endian, hence the byte swap below.
    const rom_checksum: usize = 0x32;
    const game_code: usize = 0x34;
    const savestate_offset: usize = 0x38;
    /// $100 on both: the header is 256 bytes and the input words follow it.
    const controller_offset: usize = 0x3C;
    const author: usize = 0x40;
    const author_len: usize = 64;
    const description: usize = 0x80;
    const description_len: usize = 128;
};

/// `start_flags` bits. Either one means the movie does not begin at power-on,
/// and neither can be replayed from a cold machine.
const start_from_savestate: u8 = 0x01;
const start_from_sram: u8 = 0x02;

/// The Game Boy VBA records: DMG.
const gb_dmg: u32 = 3;

/// The DMG's master clock. `lcd.zig` states the frame in cycles; this is the
/// other half of turning a frame count into a runtime.
const cpu_hz: u32 = 4_194_304;

/// One input word, in the movie's own bit order: A, B, Select, Start, then
/// Right, Left, Up, Down, each **set** when held.
///
/// The Game Boy's own order is the same, and its lines are active low, so the
/// conversion is one complement per nibble and nothing else. Both published
/// movies use only these eight bits — measured, not assumed; `Movie.extra_bits`
/// is the OR of everything above them and reads 0 for each.
/// The eight bits of `Input.held`, named. `oracle.zig` had its own copies of
/// the three the port can act on; these are the whole set, in the movie's order.
pub const held_a: u8 = 0x01;
pub const held_b: u8 = 0x02;
pub const held_select: u8 = 0x04;
pub const held_start: u8 = 0x08;
pub const held_right: u8 = 0x10;
pub const held_left: u8 = 0x20;
pub const held_up: u8 = 0x40;
pub const held_down: u8 = 0x80;

pub const Input = struct {
    raw: u16,

    pub fn buttons(self: Input) probe.Buttons {
        return .{
            .dpad = ~@as(u4, @truncate(self.raw >> 4)),
            .buttons = ~@as(u4, @truncate(self.raw)),
        };
    }

    pub fn held(self: Input) u8 {
        return @truncate(self.raw);
    }
};

pub const Movie = struct {
    /// The whole file, borrowed. Input words are read out of it on demand
    /// rather than copied into a `[]u16`, because the words are unaligned in
    /// the file and a 325 KiB copy buys nothing.
    bytes: []const u8,
    frames: usize,
    rerecords: u32,
    uid: u32,
    title: [off.title_len]u8,
    rom_crc: u8,
    rom_checksum: u16,
    controller_offset: usize,
    author: []const u8,
    description: []const u8,
    /// Everything set in any input word above bit 7 — VBA's reset and
    /// power-cycle flags live up there. 0 on both published movies, so nothing
    /// in the runner handles them; a movie that used them would show a nonzero
    /// value here and get a warning rather than a silent misreplay.
    extra_bits: u16,

    pub fn input(self: Movie, frame: usize) Input {
        if (frame >= self.frames) return .{ .raw = 0 };
        const i = self.controller_offset + frame * 2;
        return .{ .raw = std.mem.readInt(u16, self.bytes[i..][0..2], .little) };
    }

    /// The recording's own length in seconds, at the Game Boy's frame rate.
    ///
    /// 4 194 304 Hz over 70 224 cycles a frame is 59.7275 fps, which is the
    /// number TASVideos quotes its Game Boy runtimes at — 162 505 frames comes
    /// back as 45:08, the any% run's published time to the second.
    pub fn seconds(self: Movie) f64 {
        const fps = @as(f64, cpu_hz) / @as(f64, @floatFromInt(lcd_mod.frame_cycles));
        return @as(f64, @floatFromInt(self.frames)) / fps;
    }
};

fn u32At(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

/// Parse and validate a VBM, refusing anything that cannot be replayed from a
/// cold machine. Borrows `bytes`; the caller keeps them alive.
pub fn parse(bytes: []const u8) Error!Movie {
    if (bytes.len < 0x100) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], sig)) return Error.BadSignature;
    if (u32At(bytes, off.version) != 1) return Error.UnsupportedVersion;

    const start_flags = bytes[off.start_flags];
    if (start_flags & start_from_savestate != 0) return Error.StartsFromSavestate;
    if (start_flags & start_from_sram != 0) return Error.StartsFromSram;
    if (u32At(bytes, off.gb_emulator_type) != gb_dmg) return Error.NotGameBoy;
    if (bytes[off.controller_flags] & 0x01 == 0) return Error.NoControllerOne;

    const frames: usize = u32At(bytes, off.frames);
    const controller_offset: usize = u32At(bytes, off.controller_offset);
    if (controller_offset < 0x100 or controller_offset > bytes.len) return Error.Truncated;
    if ((bytes.len - controller_offset) / 2 < frames) return Error.Truncated;

    var extra: u16 = 0;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const w = std.mem.readInt(u16, bytes[controller_offset + i * 2 ..][0..2], .little);
        extra |= w & 0xFF00;
    }

    var title: [off.title_len]u8 = undefined;
    @memcpy(&title, bytes[off.title..][0..off.title_len]);

    return .{
        .bytes = bytes,
        .frames = frames,
        .rerecords = u32At(bytes, off.rerecords),
        .uid = u32At(bytes, off.uid),
        .title = title,
        .rom_crc = bytes[off.rom_crc],
        .rom_checksum = std.mem.readInt(u16, bytes[off.rom_checksum..][0..2], .little),
        .controller_offset = controller_offset,
        .author = std.mem.sliceTo(bytes[off.author..][0..off.author_len], 0),
        .description = std.mem.sliceTo(bytes[off.description..][0..off.description_len], 0),
        .extra_bits = extra,
    };
}

/// The cartridge header fields a VBM names, checked against the ROM we have.
///
/// `rom.zig` already proves the configured ROM is the expected revision; this
/// proves the *movie* was recorded on that same revision. Both directions are
/// needed: ingest cannot know about a movie, and a movie cannot know which ROM
/// it will be replayed against.
pub fn checkAgainstRom(m: Movie, rom: []const u8) Error!void {
    if (rom.len < 0x150) return Error.Truncated;
    const want_title = rom[0x134..][0..8];
    if (!std.mem.eql(u8, m.title[0..8], want_title)) return Error.TitleMismatch;
    if (m.rom_crc != rom[0x14D]) return Error.HeaderChecksumMismatch;
    // Big-endian at $14E, per the cartridge header; the VBM stores the same
    // number little-endian, which is why one side is byte-swapped.
    const global = std.mem.readInt(u16, rom[0x14E..][0..2], .big);
    if (m.rom_checksum != global) return Error.GlobalChecksumMismatch;
}

// ---- Replaying it ---------------------------------------------------------

/// When the runner advances to the next input word. See the module comment:
/// the two are not the same, and which one VBA used is not something we can
/// cite, so it was measured.
/// `.lcd` advances when LY wraps to 0, `.cycles` every 70 224 cycles, and
/// `.vblank` when LY reaches 144.
///
/// `.vblank` is the default and the other two are kept because they are what
/// made choosing it a measurement. See the module comment for both halves of
/// that measurement, and `delivery` for the one that separates `.vblank` from
/// `.lcd`: the game polls the pad at LY 149, so those five scanlines decide
/// whether it reads this frame's byte or the last one's.
pub const FrameSource = enum { lcd, cycles, vblank };

/// Where the movie's frame 0 lands on our machine, under the defaults below.
/// `findInputOrigin` is the measurement, and the test at the bottom is it
/// running again on every gate so a change to the emulator's frame timing
/// cannot silently move it.
pub const measured_input_offset: usize = 4;

/// How long a run may go without completing an LCD frame before it is called
/// stalled, in frames' worth of cycles.
///
/// Cycles rather than instructions, and generous, for the reason
/// `harness.runScript` documents: **Metroid II turns the LCD off during a
/// screen transition**, and under `.lcd` framing no boundary arrives for as
/// long as that lasts. An instruction budget sized for one frame calls that a
/// dead machine — the same mistake that capped the ledger's observation at
/// 2664 frames every time it was run.
const stall_frames: u64 = 600;

/// A per-frame callback into a replay. See `Options.watcher`.
pub const Watcher = struct {
    ctx: *anyopaque,
    /// `frame` is the movie's own frame index, and the machine is at that
    /// frame's commit point: its logic has run and the next input is not yet
    /// applied.
    onFrame: *const fn (ctx: *anyopaque, m: *harness.Machine, frame: usize) anyerror!void,
};

/// One stretch the game spent with the LCD off.
///
/// **This is the game's own signal that the player is not playing.** Metroid II
/// blanks the screen while it loads a room -- `stall_frames` above exists
/// because of it -- and no frame boundary arrives while it is off, so the
/// movie's frame index freezes for the duration and the interval is invisible
/// in a per-frame trace. Measured in cycles, which is the only clock still
/// running.
pub const Blank = struct {
    /// The movie frame in progress when the screen went off. The frame index
    /// does not advance during the blank, so this is also the frame it ends on.
    frame: u32,
    /// Master cycles the screen was off.
    cycles: u64,

    /// The blank in frames of Game Boy time, rounded to nearest.
    ///
    /// A duration is compared against a port whose frames are the unit it
    /// counts in, so the cycles have to become frames somewhere; doing it here
    /// keeps the rounding in one place and the cycles available beside it.
    pub fn frames(self: Blank) u32 {
        return @intCast((self.cycles + lcd_mod.frame_cycles / 2) / lcd_mod.frame_cycles);
    }
};

/// Cap on recorded blanks, so a game that flickers the screen cannot grow a
/// replay's memory without bound.
pub const blank_limit: usize = 4096;

pub const Options = struct {
    /// `.vblank`, measured. See the module comment: the boundary five
    /// scanlines earlier is the difference between losing 713 of the first
    /// 8000 frames' input and losing none.
    frame_source: FrameSource = .vblank,
    /// 0 means the whole movie.
    max_frames: usize = 0,
    /// Sample every Nth frame. 1 keeps every frame; a longer run can afford
    /// less without losing the shape of the trace.
    stride: usize = 1,
    /// Watch cartridge-RAM writes, which is how the loadout gets named.
    watch_save: bool = true,
    /// Cap on recorded save writes, so a game that saves repeatedly cannot
    /// grow the report without bound.
    save_limit: usize = 4096,
    /// Record which addresses were executed, for the coverage half.
    watch_exec: bool = false,
    /// Arbitrary addresses to sample on every sampled frame, written to their
    /// own table rather than into `Sample`.
    ///
    /// **A side channel on purpose.** `Sample`'s columns are read by
    /// `gb_trace.zig`, by `Track` and by three rungs of the gate, so a column
    /// added for one measurement would be a column all of them have to carry.
    /// These go into `Run.watched` instead, which nothing grades: the facility
    /// exists so a question about a specific address can be answered off the
    /// running game rather than off a comment about it. Step 17 added it to ask
    /// where `$D03B`/`$D03C` -- the bytes `drawSamus` leaves and the sprite
    /// collision reads -- go during a room transition.
    watch: []const u16 = &.{},
    /// Track every field of the save record across the run.
    ///
    /// `save.zig` recovers *which* addresses the game considers worth keeping;
    /// it cannot say what any of them mean. Watching them over eleven minutes
    /// of a tool-assisted run can: energy moves constantly and recovers,
    /// missiles fall when B is pressed, equipment only ever gains bits. The
    /// names in `save.fields` that are not position or Metroid count came from
    /// this table.
    profile_record: bool = true,
    /// Frames of machine time before the movie's frame 0 is applied.
    ///
    /// The recording emulator's frame zero and ours are not the same instant,
    /// and the difference is not something a header states. See
    /// `findInputOrigin`, which measures it: both published runs press Start
    /// within their first ten frames and then hold nothing for four seconds,
    /// so an origin that is even slightly early loses that press to the game's
    /// own initialisation and the replay sits on the title screen forever.
    input_offset: usize = measured_input_offset,
    /// Keep the last rendered frame, so the run can be looked at rather than
    /// only measured. Every field of a trace taken on the title screen is zero,
    /// and so is every field of a trace of Samus standing still in the corner
    /// of a room: a picture is the cheapest way to tell those apart, and the
    /// first version of this file needed one.
    screenshot: bool = false,
    /// Called at the end of every movie frame, before the next frame's input
    /// is applied, and regardless of `stride`.
    ///
    /// The replay loop is not a thing to have two of: it owns the input origin,
    /// the frame-boundary source and the stall deadline, and a second copy of
    /// it in `oracle.zig` would be a second place for the origin to be wrong.
    /// So the oracle takes its reference through this instead.
    watcher: ?Watcher = null,
    /// A DMG boot ROM to run through first, or null to start post-boot at
    /// $0100 the way `harness.boot` does.
    ///
    /// This is the frame-zero question and it is not cosmetic. A movie
    /// recorded with a boot ROM spends its first ~60 frames on the scrolling
    /// logo, and replaying it without one runs the game 60 frames early -- so
    /// a Start press held for ten frames at the title lands during the game's
    /// own initialisation instead, is lost, and the replay sits on the title
    /// screen for the remaining 45 minutes pressing directions at nothing.
    /// That is exactly what the first run of this file did.
    boot_rom: ?[]const u8 = null,
};

/// One frame of the reference trace.
///
/// Position and camera are the two fields Phase 0a's comparator actually
/// compares, because they are the two things the port has. The rest is here
/// because it costs a byte a frame and Phase 0b will want it.
///
/// **Enemy slots are not in this record and are not guessed at.** The plan's
/// sub-task names them, and no address in this repository pins one: nothing in
/// Phase 0a spawns an enemy, so nothing has had cause to. `wram_digest` is the
/// honest stand-in and is strictly more sensitive than a handful of named
/// slots would be — any divergence anywhere in the 8 KiB moves it — but it
/// cannot say *what* diverged, which is what pinning the slots would buy.
/// Pinned in Phase 0b, where there is something to compare them against.
pub const Sample = struct {
    frame: u32,
    /// The movie's held buttons, low byte, in the movie's own bit order.
    input: u8,
    /// `(screen << 8) | pixel` on each axis — `room.Placement.worldY/worldX`'s
    /// arithmetic, from the same four HRAM bytes.
    samus_y: u16,
    samus_x: u16,
    camera_y: u16,
    camera_x: u16,
    /// `$D020`, the byte the whole pose machine dispatches on.
    pose: u8,
    /// `$D811`, the copy the warp handler makes. Not `$D04E`, which is a
    /// shadow of whatever bank happens to be mapped — see `room.map_bank_addr`.
    map_bank: u8,
    /// `$D089`. The number the game is counting down to zero.
    metroid_count: u8,
    /// FNV-1a over all 8 KiB of WRAM. Cheap, order-fixed, and sensitive to
    /// everything the named fields miss.
    wram_digest: u32,
};

/// How one save-record field behaved over a run.
pub const FieldStat = struct {
    field: save.Field,
    /// The value at the first sampled frame, which is before the game has
    /// started and is therefore almost always zero.
    first: u8,
    /// The value at the first frame the Metroid counter is nonzero.
    ///
    /// That frame, not the frame the room loads: the room arrives a couple of
    /// frames into the movie and the loadout is written after it, so sampling
    /// on arrival reads every $D0xx field as zero. A nonzero counter is the
    /// game's own signal that a file has been set up.
    ///
    /// This is the column that identifies a field, because it is the loadout
    /// the game hands a new file, and Metroid II's starting numbers are known
    /// from playing it: 99 energy and 30 missiles.
    at_start: u8,
    last: u8,
    min: u8,
    max: u8,
    /// Frames on which it differed from the frame before.
    changes: u32,
    /// Bits that were ever set, and bits that were ever cleared after being
    /// set. A field that only ever gains bits is a collection of flags.
    bits_set: u8,
    bits_cleared: u8,
};

/// What the replay actually did, as distinct from what it was asked to do.
/// A stretch of sampled frames, plus the three aggregates a sample set cannot
/// always re-derive from itself. This is what `faithfulness` and
/// `findRefusals` grade.
///
/// It exists because the reference stopped being a thing we replay. `Run` is
/// what our own emulator produces; `gb_trace.zig` produces the same columns out
/// of Mesen2, over a recording our emulator cannot replay, and the published
/// runs produce them a third way. Grading all three through one type is the
/// difference between one grader and three copies of one.
pub const Track = struct {
    samples: []const Sample,
    /// Bit per map bank $9-$F, set when the track was ever in it.
    banks_seen: u8,
    metroid_first: u8,
    metroid_min: u8,

    pub fn bankCount(self: Track) usize {
        return @popCount(self.banks_seen);
    }

    /// The frame after the last one sampled: the track's own horizon when
    /// nothing else places one.
    ///
    /// **Not `samples.len`.** A replay's samples start at frame 0 and the two
    /// were the same number for as long as that was the only producer; a Mesen
    /// pass records a window starting wherever it was asked to, and reading
    /// its length as a frame index silently grades the wrong stretch.
    pub fn end(self: Track) u32 {
        if (self.samples.len == 0) return 0;
        return self.samples[self.samples.len - 1].frame + 1;
    }

    /// The frame spacing of the samples, or null when they are not evenly
    /// spaced. One means every frame, which is what anything measuring a
    /// *duration* in frames requires.
    pub fn stride(self: Track) ?u32 {
        if (self.samples.len < 2) return null;
        const d = self.samples[1].frame - self.samples[0].frame;
        if (d == 0) return null;
        for (self.samples[1..], self.samples[0 .. self.samples.len - 1]) |b, a| {
            if (b.frame - a.frame != d) return null;
        }
        return d;
    }

    /// Where `frame` sits in `samples`, or null when the track does not carry
    /// it. Binary search rather than subtraction, because a track's frame 0 is
    /// not its index 0 unless it happens to start at the beginning.
    pub fn indexOf(self: Track, frame: u32) ?usize {
        var lo: usize = 0;
        var hi: usize = self.samples.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const f = self.samples[mid].frame;
            if (f == frame) return mid;
            if (f < frame) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Derive the aggregates from the samples themselves.
    ///
    /// Exact when the samples are every frame, which is what a Mesen pass
    /// records. `Run` keeps its own instead, because its stride can step over
    /// the one frame a Metroid count changed on.
    pub fn ofSamples(samples: []const Sample) Track {
        var banks: u8 = 0;
        var first: u8 = 0xFF;
        var min: u8 = 0xFF;
        for (samples) |s| {
            if (s.map_bank >= room.map_bank_first and s.map_bank <= room.map_bank_last) {
                banks |= @as(u8, 1) << @intCast(s.map_bank - room.map_bank_first);
            }
            if (first == 0xFF and s.metroid_count != 0) first = s.metroid_count;
            if (s.metroid_count < min) min = s.metroid_count;
        }
        return .{
            .samples = samples,
            .banks_seen = banks,
            .metroid_first = if (first == 0xFF) 0 else first,
            .metroid_min = if (min == 0xFF) 0 else min,
        };
    }
};

pub const Run = struct {
    samples: []Sample,
    /// Input words consumed. Short of `movie.frames` means the machine stopped
    /// producing frame boundaries — a stall, which is reported rather than
    /// treated as the end of the movie.
    frames_run: usize,
    instructions: u64,
    /// Cartridge-RAM writes, empty when `watch_save` was off.
    save: room.SaveReport,
    /// Progress markers, which is how faithfulness gets judged without a VBA
    /// to compare against. A faithful replay of either published movie ends
    /// with `metroid_min` at 0 and every map bank visited.
    metroid_first: u8,
    metroid_min: u8,
    /// Bit per map bank $9-$F, set when the trace was ever in it.
    banks_seen: u8,
    /// Distinct poses observed. Step 14's random-input explorer reached three;
    /// anything that plays the game reaches far more.
    poses_seen: usize,
    /// Set when the run ended early because no frame boundary arrived.
    stalled: bool,
    /// `Options.watch`'s addresses, one row per sampled frame in `samples`
    /// order, `watch.len` bytes to a row. Empty when nothing was watched.
    watched: []u8 = &.{},

    // ---- Where the machine actually ended up ------------------------------
    //
    // A replay that never gets into the game looks identical, in every field
    // above, to one that gets in and stands still: all zeroes. These say which
    // it was, which is the difference between "the movie desynced" and "the
    // movie never started".

    /// The first frame with a map bank in range, or null if the run never
    /// entered a room. On a faithful replay this is the frame the title screen
    /// ends, and it is the single most useful number here.
    entered_frame: ?u32,
    final_pc: u16,
    final_bank: usize,
    lcd_on: bool,
    /// `harness.alive`: the LCD is on, VRAM has real content, and enough
    /// instructions have run for that to mean something.
    alive: bool,
    /// The final frame's shades, when `Options.screenshot` asked for one.
    screen: ?[ppu_mod.pixels]ppu_mod.Shade,
    /// One row per save-record field, when `Options.profile_record` asked.
    profile: []FieldStat,
    /// Every stretch the screen was off, in order. See `Blank`.
    blanks: []Blank,

    pub fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.profile);
        self.profile = &.{};
        allocator.free(self.blanks);
        self.blanks = &.{};
        allocator.free(self.samples);
        self.save.deinit(allocator);
        self.samples = &.{};
    }

    pub fn bankCount(self: Run) usize {
        return @popCount(self.banks_seen);
    }

    /// The run as the table the graders take. Its own aggregates, not
    /// `Track.ofSamples`'s: a strided run has seen frames its samples do not
    /// carry.
    pub fn track(self: Run) Track {
        return .{
            .samples = self.samples,
            .banks_seen = self.banks_seen,
            .metroid_first = self.metroid_first,
            .metroid_min = self.metroid_min,
        };
    }

    /// Whether the replay got past the title screen at all.
    ///
    /// Deliberately not "did the map bank change": the title screen leaves
    /// every one of the traced variables at zero, and so does a game that has
    /// started and put Samus at the origin -- but the second does not happen,
    /// because the warp that brings her into the landing site writes a screen
    /// and a pixel offset, and neither of the two published runs stands still.
    pub fn started(self: Run) bool {
        for (self.samples) |s| {
            if (s.samus_x != 0 or s.samus_y != 0) return true;
            if (s.map_bank >= room.map_bank_first and s.map_bank <= room.map_bank_last) return true;
        }
        return false;
    }
};

/// The last frame the replay drew, kept line by line as the PPU emits them.
///
/// The same shape as `sameboy.Grader` without the object mask: this only has
/// to be looked at, not graded.
const Screen = struct {
    ppu: ppu_mod.Ppu = .{},

    fn video(self: *Screen) bus_mod.Video {
        return .{ .ctx = @ptrCast(self), .line = onLine };
    }

    fn onLine(ctx: *anyopaque, bus: *const bus_mod.Bus, ly: u8) void {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        if (ly == 0) self.ppu.startFrame();
        self.ppu.renderLine(bus, ly);
    }
};

fn fnv1a(bytes: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (bytes) |b| {
        h ^= b;
        h = h *% 0x01000193;
    }
    return h;
}

fn apply(m: *harness.Machine, in: Input) void {
    const b = in.buttons();
    m.sys.bus.setKeys(b.dpad, b.buttons);
}

fn sampleNow(m: *harness.Machine, frame: usize, input: Input) Sample {
    const p = room.placement(m);
    return .{
        .frame = @intCast(frame),
        .input = input.held(),
        .samus_y = p.worldY(),
        .samus_x = p.worldX(),
        .camera_y = (@as(u16, m.read(camera_row_addr)) << 8) | m.read(camera_pixel_y_addr),
        .camera_x = (@as(u16, m.read(camera_col_addr)) << 8) | m.read(camera_pixel_x_addr),
        .pose = m.read(ledger.pose_addr),
        .map_bank = m.read(room.map_bank_addr),
        .metroid_count = m.read(metroid_count_addr),
        .wram_digest = fnv1a(&m.sys.bus.wram),
    };
}

/// The camera, in the same screen-over-pixel form as Samus's position.
///
/// **Corrected 2026-08-31: this was $FFCC-$FFCF, which is a different quad.**
/// `screens.zig` pinned $FFCD and $FFCF by watching which HRAM addresses the
/// frame renderer reads before drawing, and that observation is sound -- the
/// renderer does read them. It does not follow that they are the camera. They
/// are the *drawing origin*: 00:$0675 is `XOR A / LDH ($CC),A / LDH ($CE),A /
/// LDH A,($C9) / LDH ($CD),A / LDH A,($CB) / LDH ($CF),A`, which zeroes both
/// pixel halves and copies the camera's two screen bytes over. So the quad is
/// the camera rounded down to a screen, which is exactly what a renderer wants
/// and exactly what a comparator must not have: it steps in metatile units and
/// stands still in between, so the segment's camera rung was grading a
/// staircase against a slope.
///
/// The camera itself is $FFC8-$FFCB, and the routine that maintains it is
/// 00:$08FE: it builds a cell index out of $FFC9 and $FFCB, looks the screen's
/// scroll flags up in the table at $4200, and at 00:$0949 adds `$D035` -- the
/// speed `samus_walkRight` left behind at 00:$1C4D -- straight into $FFCA. A
/// routine that adds the walk speed to an address every frame is the camera.
pub const camera_pixel_y_addr: u16 = 0xFFC8;
pub const camera_row_addr: u16 = 0xFFC9;
pub const camera_pixel_x_addr: u16 = 0xFFCA;
pub const camera_col_addr: u16 = 0xFFCB;

/// The quad that used to be called the camera: the camera rounded down to a
/// whole screen, which is what the column and row draws address VRAM through.
pub const draw_origin_pixel_y_addr: u16 = 0xFFCC;
pub const draw_origin_row_addr: u16 = 0xFFCD;
pub const draw_origin_pixel_x_addr: u16 = 0xFFCE;
pub const draw_origin_col_addr: u16 = 0xFFCF;

/// `metroidCountReal`, named in `01-requirements` and the one field of the
/// trace that says whether the run is actually progressing through the game.
pub const metroid_count_addr: u16 = 0xD089;

/// Boot into a room, poke one byte, and render what the game then draws.
///
/// The evidence behind the names in `save.fields`. `save.zig` recovers which
/// addresses the record keeps and the replay profile above says how each one
/// behaves, but neither says what any of them *is*. The status bar does: it
/// draws energy, missiles and the Metroid count as digits, so writing a value
/// with distinctive digits into a candidate and looking at the bar names it.
pub const Poke = struct {
    frame: [ppu_mod.pixels]ppu_mod.Shade,
    /// Where she was when the frames ran out. A byte that is her energy kills
    /// her when it is zeroed, and the room falls away with her -- which is a
    /// far blunter signal than a status-bar digit and needs no eyes.
    after: room.Placement,
    /// Both background maps, $9800-$9FFF. The status bar is drawn through the
    /// window, so which of the two carries it is not assumed here.
    maps: [0x800]u8,
};

pub fn pokeAndDraw(
    allocator: std.mem.Allocator,
    rom: []const u8,
    where: room.Spawn,
    addr: ?u16,
    value: u8,
    frames: u64,
) !Poke {
    var m = try harness.boot(allocator, rom, harness.boot_seconds_default);
    defer m.deinit();

    _ = try room.spawn(&m, where);
    if (addr) |a| m.write(a, value);

    var screen: Screen = .{};
    m.sys.bus.video = screen.video();
    _ = try m.runFrames(frames, .{});

    var out: Poke = .{ .frame = screen.ppu.frame, .after = room.placement(&m), .maps = undefined };
    @memcpy(&out.maps, m.sys.bus.vram[0x1800..0x2000]);
    return out;
}

/// Replay `movie` on a cold machine and record what it does.
pub fn run(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: Movie,
    opts: Options,
) !Run {
    try checkAgainstRom(movie, rom);

    // Zero boot frames: the movie *is* the boot. Feeding it `bootButtons`
    // first would put the game several frames into the title screen before the
    // recording's own first input arrived, which is a desync at frame 0.
    var m = try harness.bootFrom(allocator, rom, opts.boot_rom);
    defer m.deinit();

    var screen: Screen = .{};
    if (opts.screenshot) m.sys.bus.video = screen.video();

    var log = room.SaveLog.init(allocator, opts.save_limit);
    defer log.deinit();
    if (opts.watch_save) log.attach(&m);

    const limit = if (opts.max_frames == 0) movie.frames else @min(opts.max_frames, movie.frames);

    var samples: std.ArrayList(Sample) = .empty;
    errdefer samples.deinit(allocator);
    try samples.ensureTotalCapacity(allocator, limit / opts.stride + 2);

    var poses = std.AutoHashMap(u8, void).init(allocator);
    defer poses.deinit();

    var stats: [save.fields.len]FieldStat = undefined;
    var have_stats = false;
    for (save.fields, 0..) |f, i| {
        stats[i] = .{ .field = f, .first = 0, .at_start = 0, .last = 0, .min = 0xFF, .max = 0, .changes = 0, .bits_set = 0, .bits_cleared = 0 };
    }

    var banks: u8 = 0;
    var metroid_first: u8 = 0xFF;
    var metroid_min: u8 = 0xFF;
    var stalled = false;
    var entered: ?u32 = null;

    // The screen is on at $0100 and the game blanks it to load a room, so the
    // edge to watch for first is the falling one.
    var blanks: std.ArrayList(Blank) = .empty;
    var watched: std.ArrayList(u8) = .empty;
    defer watched.deinit(allocator);
    errdefer blanks.deinit(allocator);
    var lcd_was_on = m.sys.bus.lcd.enabled();
    var blank_since: u64 = 0;

    // Machine frames elapsed, which leads the movie's own frame index by
    // `input_offset`.
    var elapsed: usize = 0;
    var frame: usize = 0;
    var next_cycle = m.sys.cpu.cycles + lcd_mod.frame_cycles;
    var prev_ly: u8 = m.sys.bus.lcd.ly;
    // The cycle at which a run with no frame boundary is declared stalled.
    var deadline = m.sys.cpu.cycles + stall_frames * lcd_mod.frame_cycles;

    // Nothing held until the origin is reached: a movie's frame 0 is almost
    // always empty anyway, and pressing its first input early is the failure
    // this offset exists to avoid.
    m.sys.bus.setKeys(0xF, 0xF);
    if (opts.input_offset == 0) apply(&m, movie.input(0));

    while (frame < limit) {
        if (opts.watch_save) log.pc = m.sys.cpu.pc;
        // The harness's execution watch, which `m.sys.step` does not offer on
        // its own. Unset unless a watcher installed one (`audio_parity.zig`
        // does, to see `handleAudio` called), so it costs a null check.
        if (m.exec) |w| {
            const pc = m.sys.cpu.pc;
            w.hit(w.ctx, if (pc < 0x4000) m.sys.bus.cart.lowBank() else m.sys.bus.cart.highBank(), pc);
        }
        const lcd_done = try m.sys.step();

        const lcd_on = m.sys.bus.lcd.enabled();
        if (lcd_was_on and !lcd_on) {
            blank_since = m.sys.cpu.cycles;
        } else if (!lcd_was_on and lcd_on and blanks.items.len < blank_limit) {
            try blanks.append(allocator, .{
                .frame = @intCast(frame),
                .cycles = m.sys.cpu.cycles - blank_since,
            });
        }
        lcd_was_on = lcd_on;

        const ly = m.sys.bus.lcd.ly;
        const boundary = switch (opts.frame_source) {
            .lcd => lcd_done,
            .cycles => m.sys.cpu.cycles >= next_cycle,
            // The 143->144 edge. A CPU step is at most a few dozen cycles and
            // a scanline is 456, so the edge cannot be stepped over.
            //
            // No frame ends while the LCD is off, exactly as under `.lcd`, and
            // that is measured rather than assumed: counting a frame every
            // 70 224 cycles through a blanked screen instead -- which is what
            // a recording emulator that must not hang has to do -- takes the
            // any% run's horizon from 8443 frames back down to 535. VBA's
            // counter stopped with the screen, and this one stops with it.
            .vblank => prev_ly < lcd_mod.visible_lines and ly >= lcd_mod.visible_lines,
        };
        prev_ly = ly;
        if (!boundary) {
            if (m.sys.cpu.cycles >= deadline) {
                stalled = true;
                break;
            }
            continue;
        }
        if (opts.frame_source == .cycles) next_cycle += lcd_mod.frame_cycles;
        deadline = m.sys.cpu.cycles + stall_frames * lcd_mod.frame_cycles;

        // Machine frame `elapsed` has just finished. Movie frame f is held
        // during machine frame `input_offset + f`, so the frames before the
        // origin run with nothing pressed and are not sampled.
        elapsed += 1;
        if (elapsed < opts.input_offset) continue;
        if (elapsed == opts.input_offset) {
            apply(&m, movie.input(0));
            continue;
        }

        const in = movie.input(frame);
        if (frame % opts.stride == 0) {
            const s = sampleNow(&m, frame, in);
            samples.appendAssumeCapacity(s);
            for (opts.watch) |addr| try watched.append(allocator, m.read(addr));
            if (s.map_bank >= room.map_bank_first and s.map_bank <= room.map_bank_last) {
                banks |= @as(u8, 1) << @intCast(s.map_bank - room.map_bank_first);
                if (entered == null) entered = s.frame;
            }
            try poses.put(s.pose, {});
            if (opts.profile_record) {
                for (&stats) |*st| {
                    const v = m.read(st.field.src);
                    if (!have_stats) st.first = v else if (v != st.last) {
                        st.changes += 1;
                        st.bits_cleared |= st.last & ~v;
                    }
                    st.last = v;
                    st.min = @min(st.min, v);
                    st.max = @max(st.max, v);
                    st.bits_set |= v;
                }
                have_stats = true;
            }
            if (metroid_first == 0xFF and s.metroid_count != 0) {
                metroid_first = s.metroid_count;
                if (opts.profile_record) {
                    for (&stats) |*st| st.at_start = m.read(st.field.src);
                }
            }
            if (s.metroid_count < metroid_min) metroid_min = s.metroid_count;
        }

        if (opts.watcher) |w| try w.onFrame(w.ctx, &m, frame);

        frame += 1;
        apply(&m, movie.input(frame));
    }

    m.sys.bus.write_watch = null;

    return .{
        .samples = try samples.toOwnedSlice(allocator),
        .frames_run = frame,
        .instructions = m.sys.instructions,
        .save = try log.report(),
        .metroid_first = if (metroid_first == 0xFF) 0 else metroid_first,
        .metroid_min = if (metroid_min == 0xFF) 0 else metroid_min,
        .banks_seen = banks,
        .poses_seen = poses.count(),
        .stalled = stalled,
        .entered_frame = entered,
        .final_pc = m.sys.cpu.pc,
        .final_bank = m.sys.bus.cart.highBank(),
        .lcd_on = m.sys.bus.lcd.enabled(),
        .alive = harness.alive(&m),
        .screen = if (opts.screenshot) screen.ppu.frame else null,
        .profile = if (opts.profile_record) try allocator.dupe(FieldStat, &stats) else &.{},
        .blanks = try blanks.toOwnedSlice(allocator),
        .watched = try watched.toOwnedSlice(allocator),
    };
}

/// The offset at which the movie's inputs actually start the game, found by
/// trying every one.
///
/// **Why this is measured and not derived.** A movie is a list of inputs
/// indexed by the recording emulator's frame counter, and nothing in the file
/// says what that counter was counting. Both published runs press Start inside
/// their first ten frames and then hold nothing for four seconds, which is the
/// title screen's "press start" and nothing else -- so if our frame 0 is
/// earlier in the game's execution than VBA's was, that press lands during the
/// game's own initialisation, is thrown away, and the replay spends 45 minutes
/// on the title screen pressing directions at it. That is not a hypothesis: it
/// is what the first run of this file did, and `Options.screenshot` is here
/// because a picture of the title screen was the thing that said so.
///
/// The probe is the game's own answer rather than ours: run each candidate
/// offset for `frames` and ask whether Samus ended up somewhere. Nothing but a
/// started game moves her off zero.
pub fn findInputOrigin(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: Movie,
    base: Options,
    max_offset: usize,
    frames: usize,
) !?usize {
    var offset: usize = 0;
    while (offset <= max_offset) : (offset += 1) {
        var opts = base;
        opts.input_offset = offset;
        opts.max_frames = frames;
        opts.stride = 1;
        opts.watch_save = false;
        opts.screenshot = false;
        var r = try run(allocator, rom, movie, opts);
        defer r.deinit(allocator);
        if (r.started()) return offset;
    }
    return null;
}

// ---- The opening, and whether the port can boot into it ---------------------
//
// Step 15b asks the port to start where the game starts rather than from a
// synthetic spawn. Whether it can is a measurement, not a judgement, and this
// is the measurement. Both published runs, replayed frame by frame:
//
//                                          any%    100%
//     Start pressed                           4       1
//     map bank in range (the room is loaded)  5       2
//     Samus placed, pose $13                  7       4
//     pose leaves $13                       325     322
//     first pixel of movement               327     324
//
// The absolute frames differ because each run presses Start on a different
// frame. Every *interval* is identical: the room loads one frame after the
// press, Samus is placed two frames after that, she is then held in pose $13
// for exactly 318 frames, and she moves two frames after that. Two independent
// recordings agreeing to the frame is what makes these the game's numbers
// rather than one movie's.
//
// She is placed at the same pixel in both, and it is not a pixel either movie
// chose -- neither has pressed a direction yet. The game puts her there.
//
// Across those 318 frames her position never changes, and the any% run holds A
// for ten frames from 118 and B for nine from 129 without changing either her
// position or her pose. The game is being offered input and is not taking it.
// A frame rendered from the middle of the stretch is the ship on the surface
// with the HUD already showing 99 energy, 30 missiles and 39 Metroids.
//
// ## What that says about Step 15b's first question
//
// Three things stand between this cart and the movie's frame 0, and only two
// of them are gaps in the port:
//
//   * **Frames 0 to the Start press are the title screen.** `gfx_titleScreen`
//     is extracted and nothing draws it; `Reset` has no screen other than a
//     room and no state to leave. This is a title screen plus a state machine.
//   * **The room load is a mechanism the port has, by another route.**
//     `RunBootScript`/`LoadScreen` off a boot record, rather than the game's
//     own transition into the landing site. Not missing, just not the same.
//   * **The 318 held frames are a scripted sequence the port cannot play.**
//     Phase 0a's pose machine has no entry for $13 and no notion of a stretch
//     of frames in which input is ignored.
//
// So the port cannot boot into the movie's frame 0 in Phase 0a, and what Phase
// 0b has to land first is named above: the title-to-game transition, and pose
// $13's scripted sequence.
//
// ## And the half that unblocks C anyway
//
// None of it is needed to make the movie the oracle, because the first frame
// the port can be compared from is `control`, not 0. At that frame the game has
// placed Samus itself -- on a screen nobody chose, at a pixel nobody chose,
// with the loadout it hands a new file -- and held her still long enough that
// the state is quiet. That is exactly what a boot record expresses. So the
// synthetic spawn `chooseStart` picks is replaced by the game's own answer,
// with no title screen and no cutscene, and the reachable-frame count is
// counted from `control` onward.

/// Where the game puts Samus for a new file, measured identically on both
/// published runs before either has pressed a direction. `(screen << 8) | pixel`
/// on each axis, the same units as `Sample.samus_y`/`samus_x`.
pub const landing_site_y: u16 = 0x07D4;
pub const landing_site_x: u16 = 0x0648;

/// `$D020` for the whole opening sequence. Phase 0a's pose machine has no entry
/// for it.
pub const landing_pose: u8 = 0x13;

/// Frames from Samus being placed to the game accepting a direction. Measured
/// as 320 on both runs, which is what makes it the game's number.
///
/// It was 318 until the frame boundary was measured on 2026-08-31. The opening
/// did not change length; where a frame is sampled did, by five scanlines, and
/// two of the game's own state changes fall inside those five lines.
pub const opening_hold_frames: u32 = 320;

/// Frames from the Start press to `$D811` naming a real map bank.
pub const opening_load_delay: u32 = 1;

/// Frames from the room loading to Samus having a position.
pub const opening_place_delay: u32 = 1;

/// There is no `opening_move_delay`, and there was one until 2026-08-31.
///
/// It read 2 on both published runs, which made it look like the game's timing
/// the way the three constants above are. Under the measured frame boundary it
/// is 4 on the any% run and 1 on the 100%, which is what it always was: the
/// number of frames each *author* took to press a direction after being handed
/// control. `release_window` is the bound that does belong to the game.

/// The landmarks of the opening, located in a replay rather than assumed.
pub const Opening = struct {
    /// First frame with any button held. On both published runs this is the
    /// Start press at the title, and nothing is held before it.
    start_pressed: u32,
    /// First frame `$D811` names a real map bank: the landing site is loaded.
    room_loaded: u32,
    /// First frame Samus has a position at all.
    placed: u32,
    placed_y: u16,
    placed_x: u16,
    placed_pose: u8,
    /// First frame after `placed` on which the pose leaves `placed_pose`. This
    /// is the game handing over control, and it is the port's frame zero.
    control: u32,
    /// First frame after `placed` on which her position changes.
    first_move: u32,

    /// Frames she is held where the game put her, with input ignored.
    pub fn holdFrames(self: Opening) u32 {
        return self.control - self.placed;
    }
};

pub const OpeningError = error{
    /// `findOpening` reads intervals between adjacent frames, so the run has
    /// to have been sampled with `Options.stride` of 1.
    NotSampledEveryFrame,
    NeverPressedStart,
    NeverLoadedRoom,
    NeverPlaced,
    /// The replay never left `placed_pose`. Long enough to see the room load
    /// and still short of `opening_hold_frames` produces exactly this, which is
    /// the point: the game is not playable when the room appears.
    NeverGainedControl,
    NeverMoved,
};

/// Locate the opening's landmarks in a replay.
///
/// Every field is the first frame satisfying a predicate on the trace, so a
/// change in the game's own timing moves the numbers rather than breaking the
/// function -- which is what lets the test below assert the *intervals* and
/// have that mean something.
pub fn findOpening(t: Track) OpeningError!Opening {
    // A `Track`, not a `Run`: our own replay is no longer the only producer of
    // one. A Mesen census pass over James's recording is a track too, and the
    // opening it carries is the one the game actually played -- which for that
    // recording is the only way to reach it at all.
    if (t.samples.len == 0) return OpeningError.NeverPressedStart;
    for (t.samples, 0..) |s, i| {
        if (s.frame != t.samples[0].frame + i) return OpeningError.NotSampledEveryFrame;
    }

    var start: ?u32 = null;
    var loaded: ?u32 = null;
    var placed: ?usize = null;
    for (t.samples, 0..) |s, i| {
        if (start == null and s.input != 0) start = s.frame;
        if (loaded == null and s.map_bank >= room.map_bank_first and s.map_bank <= room.map_bank_last) {
            loaded = s.frame;
        }
        if (placed == null and (s.samus_y != 0 or s.samus_x != 0)) placed = i;
    }
    const at = placed orelse return OpeningError.NeverPlaced;
    const origin = t.samples[at];

    var control: ?u32 = null;
    var moved: ?u32 = null;
    for (t.samples[at + 1 ..]) |s| {
        if (control == null and s.pose != origin.pose) control = s.frame;
        if (moved == null and (s.samus_y != origin.samus_y or s.samus_x != origin.samus_x)) {
            moved = s.frame;
        }
    }

    return .{
        .start_pressed = start orelse return OpeningError.NeverPressedStart,
        .room_loaded = loaded orelse return OpeningError.NeverLoadedRoom,
        .placed = origin.frame,
        .placed_y = origin.samus_y,
        .placed_x = origin.samus_x,
        .placed_pose = origin.pose,
        .control = control orelse return OpeningError.NeverGainedControl,
        .first_move = moved orelse return OpeningError.NeverMoved,
    };
}

// ---- Where the game stops taking input, and where it starts again ----------
//
// `findOpening` locates the *first* handover of control by a bespoke predicate:
// Samus is placed, and then her pose leaves the one she was placed in. That
// works once. Grading every playable stretch of a published run needs the
// general form of it, and the general form has to be built out of what a trace
// actually holds -- position, pose and the movie's own held byte -- because the
// game's state machine is not something this repository has read.
//
// The general shape is a **refusal**: a run of frames on which Samus's position
// does not change at all. That is not by itself interesting; standing still is
// allowed. Two things make one interesting, and both are measured rather than
// assumed:
//
//   - **What the movie offered during it.** A tool-assisted run does not hold a
//     direction for hundreds of frames by accident, so `offered` is the union
//     of the held bytes over the stretch.
//   - **How long after it ends she moves.** This is the discriminator, and it
//     is the whole reason this is not just a stillness detector. A stretch ends
//     when the pose changes, and the question is what that pose change was for:
//     the opening's ends with the game giving her back, and she moves two
//     frames later. Samus standing against a wall produces the same shape and
//     answers it differently -- a tapped Down crouches her, the pose changes,
//     and she still does not move, because the game was hers all along and only
//     the direction into the wall was refused.
//
// A refusal she leaves promptly is a stretch the port does not have to be able
// to play, and its end is a re-anchor point. One she does not leave is Samus
// declining to go somewhere she cannot, which over a published tool-assisted
// run means the replay is no longer on the route the movie was recorded on.
//
// **The generalisation is checked against the special case.** `findOpening`
// locates the first handover by its own predicate, and the first refusal of a
// replay of either published run has to be the same stretch, ending on the same
// frame. A test asserts exactly that; if the two ever disagree, one of them is
// wrong and it says so rather than quietly grading from two different anchors.

/// Which room a sample is in: the map bank and the screen cell her world
/// position falls in.
///
/// The cell is the high byte of each axis, which is `room.Placement`'s own
/// arithmetic run backwards -- `samus_x`/`samus_y` here are already
/// `(screen << 8) | pixel`.
pub const Room = struct {
    map_bank: u8,
    cell: u8,

    pub fn of(s: Sample) Room {
        return .{
            .map_bank = s.map_bank,
            .cell = @intCast(((s.samus_y >> 8) & 0x0F) << 4 | ((s.samus_x >> 8) & 0x0F)),
        };
    }

    pub fn eql(a: Room, b: Room) bool {
        return a.map_bank == b.map_bank and a.cell == b.cell;
    }
};

pub const Refusal = struct {
    /// First frame on which the position had already stopped changing.
    start: u32,
    frames: u32,
    samus_x: u16,
    samus_y: u16,
    /// The pose held for the whole stretch. It changing is what ends one.
    pose: u8,
    /// Every button the movie held at any point during the stretch, or-ed.
    offered: u8,
    /// Frames from the end of the stretch until her position first changes, or
    /// null if it never does again inside the replay. One and four on the
    /// opening of the two published runs, and hundreds when she is simply
    /// against a wall.
    moved_after: ?u32,

    /// The frame the pose changes, which is the game giving her back when the
    /// stretch is one the game was holding.
    pub fn handover(self: Refusal) u32 {
        return self.start + self.frames;
    }

    /// Whether the stretch ended in movement rather than in another refusal.
    /// `within` is the caller's judgement, not a constant here.
    pub fn released(self: Refusal, within: u32) bool {
        const d = self.moved_after orelse return false;
        return d <= within;
    }
};

/// Every refusal of at least `min` frames, in order.
///
/// `min` is the caller's, not a constant here: what counts as a stretch worth
/// noticing is a judgement, and burying one in this file would make every
/// number downstream depend on a choice nobody could see.
pub fn findRefusals(allocator: std.mem.Allocator, r: Track, min: u32) ![]Refusal {
    var out: std.ArrayList(Refusal) = .empty;
    errdefer out.deinit(allocator);
    if (r.samples.len == 0) return out.toOwnedSlice(allocator);

    var i: usize = 0;
    while (i < r.samples.len) {
        const head = r.samples[i];
        var j = i;
        while (j + 1 < r.samples.len and
            r.samples[j + 1].samus_x == head.samus_x and
            r.samples[j + 1].samus_y == head.samus_y and
            r.samples[j + 1].pose == head.pose) j += 1;

        const n: u32 = @intCast(j - i + 1);
        if (n >= min) {
            var offered: u8 = 0;
            for (r.samples[i .. j + 1]) |s| offered |= s.input;

            var moved_after: ?u32 = null;
            for (r.samples[j + 1 ..]) |s| {
                if (s.samus_x != head.samus_x or s.samus_y != head.samus_y) {
                    moved_after = s.frame - r.samples[j].frame;
                    break;
                }
            }

            try out.append(allocator, .{
                .start = head.frame,
                .frames = n,
                .samus_x = head.samus_x,
                .samus_y = head.samus_y,
                .pose = head.pose,
                .offered = offered,
                .moved_after = moved_after,
            });
        }
        i = j + 1;
    }
    return out.toOwnedSlice(allocator);
}

/// How far a replay of a published run stayed on the route the run was
/// recorded on.
///
/// There is no VBA here to compare against frame by frame, so this is built out
/// of what the movie's author cannot have intended. A published Metroid II run
/// visits every map bank and drives the Metroid counter to zero; it does not
/// hold a direction into a wall for hundreds of frames, and it does not end up
/// back on the title screen. Each of those is a fact about the *run*, not about
/// an emulator, which is what lets them bound a desync without a second
/// implementation to disagree with.
pub const Faithfulness = struct {
    /// First frame the map bank named a real room, and the first frame it
    /// stopped doing so afterwards. Leaving play is a death or a reset.
    entered_play: ?u32,
    left_play: ?u32,
    banks_seen: usize,
    metroid_first: u8,
    metroid_min: u8,
    /// The first refusal she did not promptly leave -- Samus declining to walk
    /// into something. On a faithful replay of a tool-assisted run there is no
    /// long one of these.
    first_stuck: ?Refusal,
    /// And the longest, which is the one worth printing.
    longest_stuck: ?Refusal,

    /// The frame after which nothing this function can see is still evidence
    /// that the replay is the published run.
    pub fn horizon(self: Faithfulness) ?u32 {
        const r = self.first_stuck orelse return self.left_play;
        const l = self.left_play orelse return r.start;
        return @min(r.start, l);
    }
};

/// How long after a refusal ends she may take to move and still count as having
/// been handed control back. The opening takes one frame on the 100% run and
/// four on the any%; this is the larger of those with room for a pose whose
/// first frame does not move her.
pub const release_window: u32 = 8;

pub fn faithfulness(allocator: std.mem.Allocator, r: Track, min: u32) !Faithfulness {
    const refusals = try findRefusals(allocator, r, min);
    defer allocator.free(refusals);

    var first: ?Refusal = null;
    var longest: ?Refusal = null;
    for (refusals) |f| {
        if (f.released(release_window)) continue;
        if (first == null) first = f;
        if (longest == null or f.frames > longest.?.frames) longest = f;
    }

    var entered: ?u32 = null;
    var left: ?u32 = null;
    for (r.samples) |s| {
        const in = s.map_bank >= room.map_bank_first and s.map_bank <= room.map_bank_last;
        if (in and entered == null) entered = s.frame;
        if (!in and entered != null and left == null) left = s.frame;
    }

    return .{
        .entered_play = entered,
        .left_play = left,
        .banks_seen = r.bankCount(),
        .metroid_first = r.metroid_first,
        .metroid_min = r.metroid_min,
        .first_stuck = first,
        .longest_stuck = longest,
    };
}

// ---- Does the game receive what the movie held? ---------------------------
//
// A published run is a list of held bytes and nothing else, so a replay that
// leaves the route has exactly two places to have gone wrong: the machine
// computed the wrong thing from the right input, or it was handed the wrong
// input. These separate them, and they are cheap because the game writes the
// answer down. Its joypad routine fills $FF80 once a frame and the pose
// machine tests it there -- `standingHandler` reaches right as
// `LDH A,($80) / BIT 4,A` at 00:$1421 -- so at the commit point of movie frame
// f, with the logic run and the next input not yet applied, $FF80 holds what
// the game acted on during f. `movie.input(f).held()` is what it was supposed
// to act on, in the same bit order, so the comparison is equality rather than
// a mapping.

/// The held pad byte the game's own joypad read leaves for the pose machine.
pub const pad_addr: u16 = 0xFF80;
/// The newly-pressed byte beside it, which the jump check reads.
pub const pressed_addr: u16 = 0xFF81;

pub const Delivery = struct {
    frame: u32,
    /// What the movie held during this frame.
    held: u8,
    /// $FF80 at the commit point: what the game acted on.
    acted: u8,
    /// $FF81 at the commit point: what it treated as newly pressed.
    pressed: u8,
    /// Reads of $FF00 during this frame. Zero means the game never asked.
    polls: u16,
    /// The machine's cycle count at this frame's commit point.
    ///
    /// A movie frame is 70 224 cycles on the recording machine, always. If a
    /// replay's frames are longer than that on average, it is spending machine
    /// time the movie does not have -- which is what a framing that stops
    /// counting while the LCD is off does at every screen transition.
    cycle: u64,
    /// The scanline the last of those reads happened on, or 255 for none.
    ///
    /// This is the number the boundary question turns on. The replay applies
    /// a frame's input when LY wraps to 0; a poll that happens near that
    /// instant is a poll whose answer depends on which side of the boundary
    /// the emulator puts it, and two emulators that disagree by a few hundred
    /// cycles will hand the game different bytes.
    poll_ly: u8,

    pub fn agrees(self: Delivery) bool {
        return self.held == self.acted;
    }
};

const DeliveryLog = struct {
    allocator: std.mem.Allocator,
    movie: Movie,
    list: std.ArrayList(Delivery) = .empty,
    polls: u16 = 0,
    poll_ly: u8 = 255,
    attached: bool = false,

    fn onRead(ctx: *anyopaque, bus: *const bus_mod.Bus, addr: u16, value: u8) void {
        _ = value;
        if (addr != bus_mod.joyp_addr) return;
        const self: *DeliveryLog = @ptrCast(@alignCast(ctx));
        self.polls += 1;
        self.poll_ly = bus.lcd.ly;
    }

    fn onFrame(ctx: *anyopaque, m: *harness.Machine, frame: usize) anyerror!void {
        const self: *DeliveryLog = @ptrCast(@alignCast(ctx));
        if (!self.attached) {
            m.sys.bus.read_watch = .{ .ctx = self, .read = onRead };
            self.attached = true;
        }
        try self.list.append(self.allocator, .{
            .frame = @intCast(frame),
            .held = self.movie.input(frame).held(),
            .acted = m.read(pad_addr),
            .pressed = m.read(pressed_addr),
            .polls = self.polls,
            .poll_ly = self.poll_ly,
            .cycle = m.sys.cpu.cycles,
        });
        self.polls = 0;
        self.poll_ly = 255;
    }
};

/// Replay `movie` and record, for every frame, what the game received.
///
/// Runs through `run` rather than beside it: the replay loop owns the input
/// origin and the frame boundary, and a second copy of it here would be a
/// second place for either to be wrong.
pub fn delivery(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: Movie,
    opts_in: Options,
) ![]Delivery {
    var log: DeliveryLog = .{ .allocator = allocator, .movie = movie };
    errdefer log.list.deinit(allocator);

    var opts = opts_in;
    opts.stride = 1;
    opts.watch_save = false;
    opts.profile_record = false;
    opts.watcher = .{ .ctx = &log, .onFrame = DeliveryLog.onFrame };

    var r = try run(allocator, rom, movie, opts);
    r.deinit(allocator);

    return log.list.toOwnedSlice(allocator);
}

/// What a run of `Delivery` rows says about where the boundary falls.
///
/// The distinction that matters is between a frame the game *declined* to read
/// and a frame whose read the boundary cut in half. Metroid II reads $FF00 a
/// fixed number of times per poll, so one poll's worth is a constant that can
/// be measured from the run itself rather than assumed. A frame with no reads
/// whose neighbour carries two polls' worth is one poll that crossed the
/// boundary. A screen transition, where the game stops reading for tens of
/// frames together, has no such partner frame -- and is not a defect, because
/// the movie's bytes for those frames were never going to be read on the
/// recording machine either.
pub const PollShape = struct {
    /// Reads of $FF00 in one poll, taken as the most common non-zero count.
    per_poll: u16,
    /// Frames on which the game read the pad.
    polled: usize,
    /// Frames whose poll landed in the neighbouring frame instead.
    drifted: usize,
    /// Frames with no poll and no partner: the game was not asking.
    idle: usize,
    /// Frames the game polled and still acted on the wrong byte.
    wrong: usize,
    /// The first drifted or wrong frame, which is the one to look at.
    first_bad: ?Delivery,

    /// Frames the game did not receive what the movie held for it.
    pub fn bad(self: PollShape) usize {
        return self.drifted + self.wrong;
    }
};

pub fn pollShape(allocator: std.mem.Allocator, ds: []const Delivery) !PollShape {
    var counts = std.AutoHashMap(u16, usize).init(allocator);
    defer counts.deinit();
    for (ds) |d| {
        if (d.polls == 0) continue;
        const e = try counts.getOrPutValue(d.polls, 0);
        e.value_ptr.* += 1;
    }
    var per_poll: u16 = 0;
    var best: usize = 0;
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* > best) {
            best = e.value_ptr.*;
            per_poll = e.key_ptr.*;
        }
    }

    var out: PollShape = .{
        .per_poll = per_poll,
        .polled = 0,
        .drifted = 0,
        .idle = 0,
        .wrong = 0,
        .first_bad = null,
    };
    for (ds, 0..) |d, i| {
        var is_bad = false;
        if (d.polls == 0) {
            const before: u16 = if (i > 0) ds[i - 1].polls else 0;
            const after: u16 = if (i + 1 < ds.len) ds[i + 1].polls else 0;
            if (per_poll != 0 and (before >= 2 * per_poll or after >= 2 * per_poll)) {
                out.drifted += 1;
                is_bad = true;
            } else out.idle += 1;
        } else {
            out.polled += 1;
            if (!d.agrees()) {
                out.wrong += 1;
                is_bad = true;
            }
        }
        if (is_bad and out.first_bad == null) out.first_bad = d;
    }
    return out;
}

// ---- How far the replay is still the published run ------------------------

/// The shortest refusal `faithfulness` will call a horizon. Below a second,
/// standing still is something a run does on purpose.
pub const stuck_min_frames: u32 = 60;

/// A published run, and the horizon its replay has to keep clearing.
///
/// Measured 2026-08-31 at `measured_input_offset` under `.vblank`: 8409 frames
/// of the any% run and 4566 of the 100%. The floors sit just under those and
/// `zig build verify` holds them, because F10 makes the reachable-frame count
/// the progress metric and a change that shortens it should fail rather than
/// be noticed a week later.
///
/// **This is a number that is meant to go up.** Raise the floor when it does.
/// For scale: before the frame boundary was measured it was 546 and 535.
pub const Published = struct {
    path: []const u8,
    name: []const u8,
    floor: u32,
};

pub const published = [_]Published{
    .{ .path = any_percent, .name = "any%", .floor = 8400 },
    .{ .path = hundred_percent, .name = "100%", .floor = 4560 },
};

/// Where a replay stopped being the published run, and what stopped it.
///
/// The reason is half the point: F10 asks for the reachable-frame count *and*
/// for what ended it each time, because that is what names the next thing to
/// build.
pub const Stop = struct {
    frame: u32,
    /// The refusal she never came out of, when that is what ended it.
    stuck: ?Refusal,
    /// Set when the replay left play -- died, or ended back at the title --
    /// at or before `frame`.
    left_play: bool,
};

/// Replay `movie` under `opts` and say where it stopped being the published
/// run, or null if it had not within the frames asked for.
pub fn horizonOf(
    allocator: std.mem.Allocator,
    rom: []const u8,
    movie: Movie,
    opts_in: Options,
) !?Stop {
    var opts = opts_in;
    opts.stride = 1;
    opts.watch_save = false;
    opts.profile_record = false;
    var r = try run(allocator, rom, movie, opts);
    defer r.deinit(allocator);
    const fs = try faithfulness(allocator, r.track(), stuck_min_frames);
    const at = fs.horizon() orelse return null;
    return .{
        .frame = at,
        .stuck = if (fs.first_stuck) |st| (if (st.start == at) st else null) else null,
        .left_play = if (fs.left_play) |l| l <= at else false,
    };
}

/// The trace as a tab-separated table, one row per sample.
pub fn tsv(allocator: std.mem.Allocator, samples: []const Sample) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(
        allocator,
        "frame\tinput\tsamus_y\tsamus_x\tcamera_y\tcamera_x\tpose\tbank\tmetroids\twram\n",
        .{},
    );
    for (samples) |s| {
        try out.print(allocator, "{d}\t{X:0>2}\t{X:0>4}\t{X:0>4}\t{X:0>4}\t{X:0>4}\t{X:0>2}\t{X:0>2}\t{d}\t{X:0>8}\n", .{
            s.frame,   s.input,    s.samus_y,       s.samus_x, s.camera_y,
            s.camera_x, s.pose,    s.map_bank, s.metroid_count, s.wram_digest,
        });
    }
    return out.toOwnedSlice(allocator);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

/// A minimal well-formed VBM: 256-byte header plus `inputs`.
fn fixture(buf: []u8, inputs: []const u16) []u8 {
    @memset(buf[0..0x100], 0);
    @memcpy(buf[0..4], sig);
    std.mem.writeInt(u32, buf[off.version..][0..4], 1, .little);
    std.mem.writeInt(u32, buf[off.frames..][0..4], @intCast(inputs.len), .little);
    buf[off.start_flags] = 0;
    buf[off.controller_flags] = 1;
    std.mem.writeInt(u32, buf[off.gb_emulator_type..][0..4], gb_dmg, .little);
    @memcpy(buf[off.title..][0..8], "METROID2");
    buf[off.rom_crc] = 0x97;
    std.mem.writeInt(u16, buf[off.rom_checksum..][0..2], 0x581F, .little);
    std.mem.writeInt(u32, buf[off.controller_offset..][0..4], 0x100, .little);
    for (inputs, 0..) |w, i| std.mem.writeInt(u16, buf[0x100 + i * 2 ..][0..2], w, .little);
    return buf[0 .. 0x100 + inputs.len * 2];
}

test "an input word becomes active-low Game Boy lines, nibble for nibble" {
    // Right and A, which is the most common word in either published movie
    // after a bare direction: $11.
    const b = (Input{ .raw = 0x11 }).buttons();
    try testing.expectEqual(@as(u4, 0b1110), b.dpad); // right pressed
    try testing.expectEqual(@as(u4, 0b1110), b.buttons); // A pressed
    // Nothing held is every line released.
    const idle = (Input{ .raw = 0 }).buttons();
    try testing.expectEqual(@as(u4, 0xF), idle.dpad);
    try testing.expectEqual(@as(u4, 0xF), idle.buttons);
    // Down and Start, the two bits at the far end of each nibble.
    const c = (Input{ .raw = 0x88 }).buttons();
    try testing.expectEqual(@as(u4, 0b0111), c.dpad);
    try testing.expectEqual(@as(u4, 0b0111), c.buttons);
}

test "a movie that cannot be replayed from a cold machine is refused by name" {
    var buf: [0x200]u8 = undefined;

    // The good one first, so the failures below are known to be caused by the
    // one field each mutates.
    _ = try parse(fixture(&buf, &[_]u16{ 0x10, 0x11 }));

    var b = fixture(&buf, &[_]u16{ 0x10, 0x11 });
    b[0] = 'X';
    try testing.expectError(Error.BadSignature, parse(b));

    b = fixture(&buf, &[_]u16{ 0x10, 0x11 });
    b[off.start_flags] = start_from_savestate;
    try testing.expectError(Error.StartsFromSavestate, parse(b));

    b = fixture(&buf, &[_]u16{ 0x10, 0x11 });
    b[off.start_flags] = start_from_sram;
    try testing.expectError(Error.StartsFromSram, parse(b));

    b = fixture(&buf, &[_]u16{ 0x10, 0x11 });
    std.mem.writeInt(u32, b[off.gb_emulator_type..][0..4], 4, .little); // GBA
    try testing.expectError(Error.NotGameBoy, parse(b));

    b = fixture(&buf, &[_]u16{ 0x10, 0x11 });
    b[off.controller_flags] = 0;
    try testing.expectError(Error.NoControllerOne, parse(b));

    // A frame count the file cannot back is truncation, not a short movie.
    b = fixture(&buf, &[_]u16{ 0x10, 0x11 });
    std.mem.writeInt(u32, b[off.frames..][0..4], 9999, .little);
    try testing.expectError(Error.Truncated, parse(b));
}

test "the movie's cartridge identity is checked against the ROM's own header" {
    var buf: [0x200]u8 = undefined;
    const m = try parse(fixture(&buf, &[_]u16{0x10}));

    var rom: [0x150]u8 = @splat(0);
    @memcpy(rom[0x134..][0..8], "METROID2");
    rom[0x14D] = 0x97;
    std.mem.writeInt(u16, rom[0x14E..][0..2], 0x581F, .big);
    try checkAgainstRom(m, &rom);

    // Each field on its own, so a passing check cannot be one field carrying
    // the other two.
    var bad = rom;
    @memcpy(bad[0x134..][0..8], "METROID1");
    try testing.expectError(Error.TitleMismatch, checkAgainstRom(m, &bad));
    bad = rom;
    bad[0x14D] = 0x96;
    try testing.expectError(Error.HeaderChecksumMismatch, checkAgainstRom(m, &bad));
    bad = rom;
    std.mem.writeInt(u16, bad[0x14E..][0..2], 0x1F58, .big);
    try testing.expectError(Error.GlobalChecksumMismatch, checkAgainstRom(m, &bad));
}

/// The published runs, fetched by `tools/get-tas.sh` into an untracked
/// directory. Absent means skip, the same contract every ROM-dependent test in
/// this repository uses.
pub const movie_dir = "vendor/tas";
pub const any_percent = movie_dir ++ "/metroid2-any.vbm";
pub const hundred_percent = movie_dir ++ "/metroid2-100.vbm";

/// A third reference input, recorded by James on 2026-09-03 in Mesen2 and
/// converted from `.mmo` to this format.
///
/// **A measurement, not a grading path, and it is kept so nobody rebuilds it.**
/// `zig build tas -- rec` replays it on our own Game Boy from a cold machine
/// and loses the run at 28 796 of 76 950 frames. That number is the third of
/// the bounds Phase 0b is planned around -- it is why the reference for Steps
/// 10-14 is a *trace taken off Mesen2* (`gb_trace.zig`) rather than a replay we
/// perform, and it is the reason `oracle.zig`'s whole anchored apparatus could
/// not simply be pointed at this recording.
///
/// It is **not** the off-by-one that cost `gb_trace.zig` a day. That defect was
/// on the Mesen side, in a harness that read `IN[f+1]`, and fixing it made the
/// *Mesen* replay whole; this path does not use that harness and its 28 796 was
/// re-measured after the fix. Nothing here grades anything: no gate reads this
/// const, and the trace readers take a `Track` precisely so that the Mesen pass
/// -- not this -- is what Steps 10-14 compare against.
pub const recorded = movie_dir ++ "/metroid2-recorded.vbm";

fn loadMovie(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        allocator,
        .limited(4 << 20),
    ) catch null;
}

test "both published movies name the cartridge we build against" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    for ([_][]const u8{ any_percent, hundred_percent }) |path| {
        const bytes = try loadMovie(a, path) orelse return error.SkipZigTest;
        defer a.free(bytes);
        const m = try parse(bytes);
        try checkAgainstRom(m, rom);
        // Both are long recordings of the whole game, not test fixtures.
        try testing.expect(m.frames > 100_000);
        try testing.expect(m.seconds() > 40 * 60);
        // Nothing above the eight button bits, which is what lets the runner
        // ignore VBA's reset flags entirely.
        try testing.expectEqual(@as(u16, 0), m.extra_bits);
    }
}

test "the measured origin is where the movie's inputs start the game" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = try loadMovie(a, hundred_percent) orelse return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try parse(bytes);

    // Nine hundred frames is fifteen seconds, which is several times what the
    // game takes to get from the title to the landing site.
    const probe_opts: Options = .{ .max_frames = 900, .watch_save = false };

    var good = try run(a, rom, movie, probe_opts);
    defer good.deinit(a);
    try testing.expect(good.started());

    // One frame early and the Start press held over the movie's frames 1-10
    // lands before the title screen will take it, and the replay never leaves
    // the title. This is the whole reason `measured_input_offset` exists, and
    // a change to the emulator's frame timing that moved it would otherwise
    // show up as a silently shorter reference trace.
    var early = probe_opts;
    early.input_offset = 0;
    var bad = try run(a, rom, movie, early);
    defer bad.deinit(a);
    try testing.expect(!bad.started());
}

test "the opening is the game's, not the movie's: both runs agree on every interval" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    // Long enough to clear `opening_hold_frames` with room to spare, short
    // enough that running it twice costs a second.
    const opts: Options = .{ .max_frames = 400, .stride = 1, .watch_save = false, .profile_record = false };

    var found: [2]Opening = undefined;
    for ([_][]const u8{ any_percent, hundred_percent }, 0..) |path, i| {
        const bytes = try loadMovie(a, path) orelse return error.SkipZigTest;
        defer a.free(bytes);
        var r = try run(a, rom, try parse(bytes), opts);
        defer r.deinit(a);
        found[i] = try findOpening(r.track());
    }

    for (found) |op| {
        // Where the game puts her, on a screen neither movie has yet asked for.
        try testing.expectEqual(landing_site_y, op.placed_y);
        try testing.expectEqual(landing_site_x, op.placed_x);
        try testing.expectEqual(landing_pose, op.placed_pose);

        // The intervals, which are the game's timing rather than the movie's.
        try testing.expectEqual(op.start_pressed + opening_load_delay, op.room_loaded);
        try testing.expectEqual(op.room_loaded + opening_place_delay, op.placed);
        try testing.expectEqual(opening_hold_frames, op.holdFrames());
        // Not an interval of the game's: how long each author waited before
        // pressing a direction. What the game bounds is that she *can* move
        // once control is back, which is what `release_window` says.
        try testing.expect(op.first_move > op.control);
        try testing.expect(op.first_move - op.control <= release_window);
    }

    // Each movie presses Start on its own frame -- so the agreement above is
    // two independent recordings, not the same number twice.
    try testing.expect(found[0].start_pressed != found[1].start_pressed);
}

test "the room appearing is not the game becoming playable" {
    // The answer Step 15b would have assumed without measuring: that the movie
    // is in play once the landing site is loaded, so the port could be compared
    // from the frame the room arrives. It is wrong by 318 frames, and this is
    // the test that fails if it is substituted back in.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = try loadMovie(a, any_percent) orelse return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try parse(bytes);

    const base: Options = .{ .stride = 1, .watch_save = false, .profile_record = false };

    // Two hundred frames is well past the room load and well short of control.
    var short = base;
    short.max_frames = 200;
    var r_short = try run(a, rom, movie, short);
    defer r_short.deinit(a);
    // The room is there and she is in it...
    try testing.expect(r_short.entered_frame != null);
    try testing.expect(r_short.entered_frame.? < 60);
    // ...and she has not been given control, so there is nothing to compare.
    try testing.expectError(OpeningError.NeverGainedControl, findOpening(r_short.track()));

    // A stride that skips frames cannot be used to measure intervals, and says
    // so rather than reporting a wrong one.
    var strided = base;
    strided.max_frames = 400;
    strided.stride = 4;
    var r_strided = try run(a, rom, movie, strided);
    defer r_strided.deinit(a);
    try testing.expectError(OpeningError.NotSampledEveryFrame, findOpening(r_strided.track()));
}

test "replaying the published run reaches the landing site and plays" {
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = try loadMovie(a, hundred_percent) orelse return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try parse(bytes);

    var r = try run(a, rom, movie, .{ .max_frames = 6000, .watch_save = false });
    defer r.deinit(a);

    try testing.expect(!r.stalled);
    try testing.expectEqual(@as(usize, 6000), r.frames_run);
    // In a room, in a map bank, within the first few frames: the movie's Start
    // press is answered by the game loading the landing site.
    try testing.expect(r.entered_frame != null);
    try testing.expect(r.entered_frame.? < 60);
    // More than one bank, so the replay is walking through door transitions
    // rather than standing where it was put.
    try testing.expect(r.bankCount() >= 2);
    // The pose machine is being exercised. Step 14's random-input explorer
    // reached three poses in ninety seconds and never once jumped; a hundred
    // seconds of a tool-assisted run is a different kind of input entirely.
    try testing.expect(r.poses_seen >= 6);
    // And she is somewhere, which is the field the comparator will compare.
    var moved = false;
    for (r.samples) |s| moved = moved or (s.samus_x != 0 and s.samus_y != 0);
    try testing.expect(moved);
}
test "the general refusal detector finds the opening the special case found" {
    // `findOpening` locates the first handover by its own predicate: Samus
    // placed, then the pose leaving the one she was placed in. `findRefusals`
    // knows nothing about openings. On both published runs they have to be the
    // same stretch, or the re-anchored comparison would be grading from a
    // different frame than Step 15b measured.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    for ([_][]const u8{ any_percent, hundred_percent }) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(8 << 20)) catch continue;
        defer a.free(bytes);
        var r = try run(a, rom, try parse(bytes), .{
            .max_frames = 500, .stride = 1, .watch_save = false, .profile_record = false,
        });
        defer r.deinit(a);

        const op = try findOpening(r.track());
        const rs = try findRefusals(a, r.track(), 60);
        defer a.free(rs);

        try testing.expect(rs.len >= 1);
        const first = rs[0];
        try testing.expectEqual(op.placed, first.start);
        try testing.expectEqual(landing_pose, first.pose);
        try testing.expectEqual(opening_hold_frames, first.frames);
        try testing.expectEqual(op.control, first.handover());
        // And it is a stretch the game gave back: she moves almost at once.
        try testing.expect(first.released(release_window));
    }
}

test "each published run clears its horizon floor, and the boundary five scanlines later does not" {
    // **The measurement that bounds every whole-game claim built on this file.**
    //
    // A replay is only the published run for as long as it stays on the route
    // the run was recorded on, and there is no VBA here to say when it stops.
    // What says it instead is something the author cannot have intended: a
    // tool-assisted run does not hold a direction for hundreds of frames while
    // Samus stands still and then not move for hundreds more once the pose has
    // changed. That is Samus against something she cannot pass.
    //
    // Two halves, and the second is what makes the first mean anything. The
    // floors have to be cleared -- and the framing this file used until
    // 2026-08-31, LY wrap rather than LY 144, has to fail them. That is the
    // difference between a threshold and a number somebody wrote down.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);

    for (published) |p| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, p.path, a, .limited(8 << 20)) catch continue;
        defer a.free(bytes);
        const movie = try parse(bytes);

        // A window comfortably past the floor, so clearing it is a measurement
        // and not the window running out.
        const window = p.floor + 600;
        const got = try horizonOf(a, rom, movie, .{ .max_frames = window });
        if (got) |stop| try testing.expect(stop.frame >= p.floor);

        // The old framing, at the origin that was measured for it. Both runs
        // walked into a wall inside 600 frames under it.
        const before = try horizonOf(a, rom, movie, .{
            .max_frames = window,
            .frame_source = .lcd,
            .input_offset = 1,
        });
        try testing.expect(before != null);
        try testing.expect(before.?.frame < p.floor);
        // And it is Samus against something she cannot pass, not a death.
        try testing.expect(before.?.stuck != null);
    }
}

test "the game receives every byte the movie holds, and under the old boundary it does not" {
    // Why the horizon moved, stated as the thing that was actually wrong.
    //
    // Metroid II polls the pad inside its VBlank handler, at LY 149. `.lcd`
    // applies a frame's input at the LY wrap, four lines later, which leaves
    // the poll pressed against the boundary -- and the game's frame is not a
    // fixed length, so the poll drifts across it and the game reads the
    // previous frame's byte. `.vblank` moves the boundary to LY 144, five
    // lines before the poll, and the drift has nowhere to land.
    //
    // Neither claim is asserted from the outside: both come from $FF80, which
    // is where the game's own joypad routine leaves what it read.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, any_percent, a, .limited(8 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try parse(bytes);

    const window = 1000;

    const good = try delivery(a, rom, movie, .{ .max_frames = window });
    defer a.free(good);
    const gs = try pollShape(a, good);
    try testing.expectEqual(@as(usize, 0), gs.bad());

    // The poll is ten reads of $FF00 and it happens every frame the game is
    // asking, which is what makes a frame with none and a frame with twenty
    // one poll that crossed a boundary rather than a frame the game skipped.
    try testing.expectEqual(@as(u16, 10), gs.per_poll);

    const bad = try delivery(a, rom, movie, .{
        .max_frames = window,
        .frame_source = .lcd,
        .input_offset = 1,
    });
    defer a.free(bad);
    const bs = try pollShape(a, bad);
    try testing.expect(bs.bad() > 0);
    // And it starts long before anything the port is graded on ends.
    try testing.expect(bs.first_bad.?.frame < 500);
}

test "a track derived from samples grades the same as the run that produced them" {
    // The generalisation Step 8 needed: `faithfulness` and `findRefusals` used
    // to take a `Run`, which only our own emulator produces. A trace taken off
    // another emulator -- `gb_trace.zig` takes one off Mesen2, over a recording
    // this emulator cannot replay -- has samples and nothing else, so the
    // graders take a `Track` and `Run` supplies one.
    //
    // At stride 1 the derived aggregates are the run's own, which is what makes
    // the substitution safe. This asserts that rather than assuming it.
    const a = testing.allocator;
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, "vendor/tas/metroid2-any.vbm", a, .limited(8 << 20)) catch return error.SkipZigTest;
    defer a.free(bytes);
    const movie = try parse(bytes);

    var r = try run(a, rom, movie, .{ .max_frames = 2000, .stride = 1 });
    defer r.deinit(a);

    const carried = r.track();
    const derived = Track.ofSamples(r.samples);
    try testing.expectEqual(carried.banks_seen, derived.banks_seen);
    try testing.expectEqual(carried.metroid_first, derived.metroid_first);
    try testing.expectEqual(carried.metroid_min, derived.metroid_min);

    const fa = try faithfulness(a, carried, stuck_min_frames);
    const fb = try faithfulness(a, derived, stuck_min_frames);
    try testing.expectEqual(fa.entered_play, fb.entered_play);
    try testing.expectEqual(fa.banks_seen, fb.banks_seen);
    try testing.expectEqual(fa.first_stuck == null, fb.first_stuck == null);

    // And a strided run is why `Run` keeps its own: the samples it hands back
    // can step over the frame an aggregate changed on, so the derivation is a
    // fallback for tracks that have nothing else, not a replacement.
    var strided = try run(a, rom, movie, .{ .max_frames = 2000, .stride = 64 });
    defer strided.deinit(a);
    try testing.expect(strided.samples.len < r.samples.len);
}
