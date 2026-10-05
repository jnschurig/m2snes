//! Grading our PPU against SameBoy.
//!
//! SameBoy is the accuracy benchmark for DMG rendering, and background-only
//! rasterisation admits no tolerance: no filtering, no blending, no sprite
//! priority to argue about. Either the same pixels come out or ours is wrong.
//! So the comparison here is equality over all 23,040 pixels, not a threshold.
//!
//! Three details make it a real comparison rather than merely a green one.
//!
//! **Both sides share a cycle origin.** Our emulator normally starts at $0100
//! from documented post-boot register values, which leaves an unknown offset
//! against SameBoy's power-on frame counter -- and on a static title screen
//! that offset is not even recoverable, since every frame matches every other.
//! So the comparison runs from power-on with SameBoy's *own* boot ROM mapped:
//! its reimplementation, assembled from source under `vendor/`, never
//! Nintendo's and never tracked. Cycle zero then means the same thing on both
//! sides, which is what makes *gameplay* comparable -- and gameplay is the
//! point, because a title screen exercises tilemap fetch and BGP and nothing
//! else. Scrolling, the window, and the mid-frame status-bar split, the parts a
//! room renderer actually leans on, only appear once the game is running.
//! SameBoy's tester drives Start and A on a schedule keyed to a 69905-cycle
//! tick; `testerButtons` reproduces it exactly, so both emulators get the same
//! input on the same cycle.
//!
//! **Objects are excluded, not compared, with slack.** This PPU draws background and window
//! only and SameBoy draws everything, so they disagree wherever a sprite covers
//! the screen -- on the title screen that is the blinking "START 1", 153 pixels
//! of it. Rather than loosen the comparison to a threshold, every pixel an
//! object could reach is masked out and what remains is compared exactly. The
//! masked fraction is reported and bounded, so a mask that grew until it hid a
//! real failure would fail on its own. The mask is sampled per scanline, at the
//! moment the line is drawn: reading OAM once at vblank looks equivalent and is
//! not, because Metroid II moves Samus's objects during the visible frame.
//!
//! The mask is then dilated by `object_slack` pixels, and that is a real
//! concession rather than a rounding detail. Our OAM and SameBoy's do not
//! always agree: on two of ten captures our emulator puts Samus a few pixels
//! from where SameBoy puts her, so SameBoy draws object pixels just outside our
//! mask. That is a state divergence somewhere in the emulator, not a rasteriser
//! bug -- the backgrounds around it are identical to the pixel -- but it is not
//! resolved, and the slack is what lets a background comparison proceed without
//! being hostage to it. `strictDiffering` still counts the undilated
//! disagreement, and the test prints it every run so the number cannot quietly
//! grow.
//!
//! **The palette is shared across captures.** An individual frame can
//! legitimately use three shades or one -- the game fades between rooms -- and
//! ranking those by luminance in isolation would renumber them, turning a
//! correct frame into a mismatch and, worse, a wrong frame into a match. One
//! palette taken from the union of every capture cannot do that.

const std = @import("std");
const system = @import("system.zig");
const bus_mod = @import("bus.zig");
const ppu_mod = @import("ppu.zig");

pub const dir = "reference/sameboy";

pub const Error = error{ NotABmp, UnsupportedBmp, WrongSize, NotFourShades, ColourNotInPalette };

/// SameBoy's four DMG colours, lightest first.
pub const Palette = [4]u32;

/// How far the object mask is dilated. One sprite height: the observed
/// divergence in object placement is a few pixels, and a whole sprite is the
/// most a single mispositioned object can hide.
pub const object_slack: usize = 8;

pub const Frame = struct {
    /// One shade index 0-3 per pixel, row-major, 160 wide. 0 is lightest.
    pixels: [ppu_mod.pixels]u8,
    /// True where an object could have drawn, and so where a background-only
    /// renderer has nothing to say. Always false for a frame read from a BMP.
    obj: [ppu_mod.pixels]bool = @splat(false),

    pub fn eql(a: Frame, b: Frame) bool {
        return a.differing(b) == 0;
    }

    /// Pixels that differ outside either frame's object mask, undilated.
    pub fn strictDiffering(a: Frame, b: Frame) usize {
        var n: usize = 0;
        for (a.pixels, b.pixels, a.obj, b.obj) |x, y, ma, mb| {
            if (ma or mb) continue;
            n += @intFromBool(x != y);
        }
        return n;
    }

    /// Pixels that differ more than `object_slack` away from any object.
    pub fn differing(a: Frame, b: Frame) usize {
        var n: usize = 0;
        for (0..ppu_mod.height) |y| {
            for (0..ppu_mod.width) |x| {
                const i = y * ppu_mod.width + x;
                if (a.pixels[i] == b.pixels[i]) continue;
                if (a.nearObject(x, y) or b.nearObject(x, y)) continue;
                n += 1;
            }
        }
        return n;
    }

    fn nearObject(self: Frame, x: usize, y: usize) bool {
        const y0 = y -| object_slack;
        const y1 = @min(y + object_slack + 1, ppu_mod.height);
        const x0 = x -| object_slack;
        const x1 = @min(x + object_slack + 1, ppu_mod.width);
        for (y0..y1) |yy| {
            for (x0..x1) |xx| {
                if (self.obj[yy * ppu_mod.width + xx]) return true;
            }
        }
        return false;
    }

    pub fn masked(self: Frame) usize {
        var n: usize = 0;
        for (self.obj) |m| n += @intFromBool(m);
        return n;
    }
};

/// A PPU plus the object mask for the frame it is drawing.
///
/// Both hang off one `bus.Video`, so the mask comes from the OAM the PPU is
/// looking at, line by line. It lives here rather than in `ppu.zig` to keep the
/// renderer a renderer: nothing in the shipped path knows a comparison against
/// another emulator exists.
pub const Grader = struct {
    ppu: ppu_mod.Ppu = .{},
    obj: [ppu_mod.pixels]bool = @splat(false),
    prev: [ppu_mod.pixels]bool = @splat(false),

    pub fn video(self: *Grader) bus_mod.Video {
        return .{ .ctx = @ptrCast(self), .line = onLine };
    }

    fn onLine(ctx: *anyopaque, bus: *const bus_mod.Bus, ly: u8) void {
        const self: *Grader = @ptrCast(@alignCast(ctx));
        if (ly == 0) {
            self.ppu.startFrame();
            self.obj = self.prev;
            self.prev = @splat(false);
        }
        self.ppu.renderLine(bus, ly);
        self.markLine(bus, ly);
    }

    /// Every pixel of this line an object could reach.
    ///
    /// The whole sprite width, not just its opaque pixels: colour 0 in an
    /// object is transparent and the background shows through, so a tighter
    /// mask would need this file to decode objects -- the very thing Step 7
    /// leaves out. Conservative and simple wins; the test bounds the cost.
    fn markLine(self: *Grader, bus: *const bus_mod.Bus, ly: u8) void {
        const lcdc = bus.lcd.lcdc;
        if (lcdc & 0x02 == 0) return; // objects disabled
        const tall: i32 = if (lcdc & 0x04 != 0) 16 else 8;
        const row = self.obj[@as(usize, ly) * ppu_mod.width ..][0..ppu_mod.width];
        for (0..40) |i| {
            const oy = @as(i32, bus.oam[i * 4]) - 16;
            const ox = @as(i32, bus.oam[i * 4 + 1]) - 8;
            if (@as(i32, ly) < oy or @as(i32, ly) >= oy + tall) continue;
            var dx: i32 = 0;
            while (dx < 8) : (dx += 1) {
                const x = ox + dx;
                if (x >= 0 and x < ppu_mod.width) {
                    row[@intCast(x)] = true;
                    self.prev[@as(usize, ly) * ppu_mod.width + @as(usize, @intCast(x))] = true;
                }
            }
        }
    }

    pub fn frame(self: Grader) Frame {
        return .{ .pixels = self.ppu.frame, .obj = self.obj };
    }
};

// ---- Reading SameBoy's captures -------------------------------------------

/// The 24-bit colours of a BMP dump, top row first.
fn bmpPixels(bytes: []const u8, out: *[ppu_mod.pixels]u32) !void {
    if (bytes.len < 0x36 or bytes[0] != 'B' or bytes[1] != 'M') return Error.NotABmp;
    const pix_off = std.mem.readInt(u32, bytes[0x0A..][0..4], .little);
    const w = std.mem.readInt(i32, bytes[0x12..][0..4], .little);
    const h = std.mem.readInt(i32, bytes[0x16..][0..4], .little);
    const bpp = std.mem.readInt(u16, bytes[0x1C..][0..2], .little);
    if (bpp != 32) return Error.UnsupportedBmp;
    if (w != ppu_mod.width or (h != -@as(i32, ppu_mod.height) and h != ppu_mod.height)) return Error.WrongSize;
    if (pix_off + ppu_mod.pixels * 4 > bytes.len) return Error.WrongSize;
    const top_down = h < 0;

    for (0..ppu_mod.height) |y| {
        const src_row = if (top_down) y else ppu_mod.height - 1 - y;
        for (0..ppu_mod.width) |x| {
            const i = src_row * ppu_mod.width + x;
            out[y * ppu_mod.width + x] =
                std.mem.readInt(u32, bytes[pix_off + i * 4 ..][0..4], .little) & 0x00FF_FFFF;
        }
    }
}

/// Accumulate the distinct colours of a capture into `seen`.
pub fn collectColours(allocator: std.mem.Allocator, bytes: []const u8, seen: *std.ArrayList(u32)) !void {
    var raw: [ppu_mod.pixels]u32 = undefined;
    try bmpPixels(bytes, &raw);
    for (raw) |c| {
        if (std.mem.indexOfScalar(u32, seen.items, c) == null) try seen.append(allocator, c);
    }
}

/// Order the colours seen across every capture, lightest first. Exactly four,
/// because that is what a DMG produces.
pub fn paletteFrom(seen: []u32) !Palette {
    if (seen.len != 4) return Error.NotFourShades;
    std.mem.sort(u32, seen, {}, struct {
        fn gt(_: void, a: u32, b: u32) bool {
            return luminance(a) > luminance(b);
        }
    }.gt);
    return .{ seen[0], seen[1], seen[2], seen[3] };
}

/// Read a BMP dump and quantise it through a known palette.
pub fn readBmp(bytes: []const u8, palette: Palette) !Frame {
    var raw: [ppu_mod.pixels]u32 = undefined;
    try bmpPixels(bytes, &raw);
    var f: Frame = .{ .pixels = @splat(0) };
    for (raw, 0..) |c, i| {
        f.pixels[i] = for (palette, 0..) |p, k| {
            if (p == c) break @intCast(k);
        } else return Error.ColourNotInPalette;
    }
    return f;
}

fn luminance(c: u32) u32 {
    const b = c & 0xFF;
    const g = (c >> 8) & 0xFF;
    const r = (c >> 16) & 0xFF;
    return 2 * r + 3 * g + b;
}

// ---- Reproducing the tester's run ------------------------------------------

/// The tester's tick: 139810 of SameBoy's 8 MHz units, which is 69905 t-cycles.
/// Deliberately not a real frame (70224) -- SameBoy picks a period that drifts
/// against vblank on purpose, so a game cannot accidentally sync to the button
/// schedule. Reproduced exactly, drift included.
pub const tick_cycles: u32 = 69905;

pub const Buttons = struct {
    /// Active low, as the hardware reports them: bit 0 right/A, 1 left/B,
    /// 2 up/select, 3 down/start.
    dpad: u4 = 0xF,
    buttons: u4 = 0xF,
};

/// SameBoy's `--start` schedule: Start held for ticks 0-9 of every 40, A for
/// ticks 20-29, and nothing during the last two seconds so a press cannot make
/// the game reload graphics while the screenshot is being taken.
pub fn testerButtons(tick: usize, length_ticks: usize) Buttons {
    var b: Buttons = .{};
    if (tick + 120 >= length_ticks) return b;
    const phase = tick % 40;
    if (phase < 10) b.buttons &= ~@as(u4, 0b1000); // Start
    if (phase >= 20 and phase < 30) b.buttons &= ~@as(u4, 0b0001); // A
    return b;
}

pub const StallError = error{EmulatorStalled};

/// Run from power-on through `boot` and return the frame SameBoy's tester would
/// have dumped for `--length seconds`. The tester writes its BMP at the first
/// vblank once its tick counter reaches the target, so that is when this
/// snapshots.
pub fn captureBooted(
    allocator: std.mem.Allocator,
    rom: []const u8,
    boot: []const u8,
    seconds: usize,
    with_input: bool,
) !Frame {
    const ram = try allocator.alloc(u8, 0x2000);
    defer allocator.free(ram);
    @memset(ram, 0);

    var sys = try system.System.initWithBoot(rom, ram, boot);
    var grader: Grader = .{};
    sys.bus.video = grader.video();

    const target = seconds * 60;
    var tick: usize = 0;
    var acc: u32 = 0;
    var prev_ly: u8 = 0;
    // A ceiling rather than an unbounded loop: a stuck emulator should fail the
    // gate, not hang it. Two hundred thousand instructions per tick is about
    // two hundred times what a tick actually takes.
    var guard: u64 = 0;
    const limit: u64 = @as(u64, target + 600) * 200_000;

    while (guard < limit) : (guard += 1) {
        const before = sys.cpu.cycles;
        _ = try sys.step();

        // Order matters, and it is SameBoy's order. Its vblank callback fires
        // from *inside* `GB_run`, before the main loop adds that step's cycles
        // and bumps the tick counter -- so the screenshot decision sees the
        // count as of the previous step. Bumping first instead lands one frame
        // late, which shows up as Samus three pixels from where SameBoy drew
        // her while every background pixel still agrees.
        if (sys.bus.lcd.ly == 144 and prev_ly == 143 and tick >= target) return grader.frame();
        prev_ly = sys.bus.lcd.ly;

        acc += @intCast(sys.cpu.cycles - before);
        if (acc >= tick_cycles) {
            acc -= tick_cycles;
            tick += 1;
            if (with_input) {
                const b = testerButtons(tick, target);
                sys.bus.setKeys(b.dpad, b.buttons);
            }
        }
    }
    return StallError.EmulatorStalled;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const build_options = @import("build_options");
const testrom = @import("testrom");
const png = @import("png");

fn fakeBmp(buf: *[0x36 + ppu_mod.pixels * 4]u8, colours: []const u32) void {
    buf.* = @splat(0);
    buf[0] = 'B';
    buf[1] = 'M';
    std.mem.writeInt(u32, buf[0x0A..][0..4], 0x36, .little);
    std.mem.writeInt(i32, buf[0x12..][0..4], ppu_mod.width, .little);
    std.mem.writeInt(i32, buf[0x16..][0..4], -@as(i32, ppu_mod.height), .little);
    std.mem.writeInt(u16, buf[0x1C..][0..2], 32, .little);
    for (0..ppu_mod.pixels) |i| {
        std.mem.writeInt(u32, buf[0x36 + i * 4 ..][0..4], colours[i % colours.len], .little);
    }
}

test "the palette comes from every capture at once, not one frame" {
    const gpa = testing.allocator;
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(gpa);

    var full: [0x36 + ppu_mod.pixels * 4]u8 = undefined;
    var faded: [0x36 + ppu_mod.pixels * 4]u8 = undefined;
    fakeBmp(&full, &.{ 0xFFFFFF, 0xAAAAAA, 0x555555, 0x000000 });
    // A fade down to two shades. Ranked on its own this would quantise to 0
    // and 1; through the shared palette it must stay 0 and 3.
    fakeBmp(&faded, &.{ 0xFFFFFF, 0x000000 });

    try collectColours(gpa, &full, &seen);
    try collectColours(gpa, &faded, &seen);
    const pal = try paletteFrom(seen.items);
    try testing.expectEqual(@as(u32, 0xFFFFFF), pal[0]);
    try testing.expectEqual(@as(u32, 0x000000), pal[3]);

    const f = try readBmp(&faded, pal);
    try testing.expectEqual(@as(u8, 0), f.pixels[0]);
    try testing.expectEqual(@as(u8, 3), f.pixels[1]);
}

test "a capture with a colour outside the palette is refused" {
    var buf: [0x36 + ppu_mod.pixels * 4]u8 = undefined;
    fakeBmp(&buf, &.{0x123456});
    const pal: Palette = .{ 0xFFFFFF, 0xAAAAAA, 0x555555, 0x000000 };
    try testing.expectError(Error.ColourNotInPalette, readBmp(&buf, pal));
}

test "a set of captures that never shows four shades is refused" {
    var seen = [_]u32{ 0xFFFFFF, 0x000000 };
    try testing.expectError(Error.NotFourShades, paletteFrom(&seen));
}

test "the tester's button schedule, including its quiet tail" {
    // Start for the first quarter of each 40-tick cycle, A for the third.
    try testing.expectEqual(@as(u4, 0b0111), testerButtons(0, 10000).buttons);
    try testing.expectEqual(@as(u4, 0b1111), testerButtons(10, 10000).buttons);
    try testing.expectEqual(@as(u4, 0b1110), testerButtons(20, 10000).buttons);
    try testing.expectEqual(@as(u4, 0b1111), testerButtons(30, 10000).buttons);
    try testing.expectEqual(@as(u4, 0b0111), testerButtons(40, 10000).buttons);
    // Nothing at all in the last two seconds, whatever the phase says.
    try testing.expectEqual(@as(u4, 0b1111), testerButtons(9880, 10000).buttons);
    try testing.expectEqual(@as(u4, 0b1111), testerButtons(9920, 10000).buttons);
}

// ---- ROM-dependent ---------------------------------------------------------

/// Captures written by `tools/sameboy-frames.sh`, in seconds from power-on.
const still_captures = [_]usize{ 2, 4, 6, 10 };
const start_captures = [_]usize{ 8, 12, 16, 20, 24, 30 };

const boot_path = "vendor/sameboy/build/bin/tester/dmg_boot.bin";

fn loadFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch null;
}

fn configuredRom(io: std.Io, allocator: std.mem.Allocator) !?[]const u8 {
    if (build_options.rom_path.len == 0) return null;
    return try std.Io.Dir.cwd().readFileAlloc(io, build_options.rom_path, allocator, .limited(1 << 20));
}

fn captureBytes(io: std.Io, allocator: std.mem.Allocator, kind: []const u8, secs: usize) !?[]u8 {
    var buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, dir ++ "/{s}-{d}/m2.bmp", .{ kind, secs }) catch unreachable;
    return loadFile(io, allocator, path);
}

/// What the comparison found. Reported by the gate rather than printed from
/// inside the test: a test that writes to stderr makes the build runner print
/// `failed command:` beside a passing step, which reads as a red gate. The
/// numbers still surface on every run -- `zig build verify` prints them next to
/// every other check -- and the test still fails on any of them going wrong.
pub const Summary = struct {
    /// Captures compared.
    compared: usize,
    /// How many of those were in play rather than on the title screen.
    in_play: usize,
    /// Mean pixels per frame masked out as object coverage.
    avg_masked: usize,
    /// Pixels differing with no `object_slack` dilation at all, totalled.
    strict_total: usize,
    /// How many captures carried such a residual.
    strict_frames: usize,
    /// The same count restricted to the still captures. Nothing moves there,
    /// so the slack must not be load-bearing: this has to be zero.
    still_strict: usize,
};

/// Why a comparison could not run. Each is a missing input, not a failure --
/// the ROM and the SameBoy captures are both untracked by design.
pub const Skipped = enum {
    no_rom,
    no_boot_rom,
    no_captures,

    pub fn why(self: Skipped) []const u8 {
        return switch (self) {
            .no_rom => "no ROM configured (set M2_ROM; see docs/setup.md)",
            .no_boot_rom => "no " ++ boot_path ++ " -- run tools/sameboy-frames.sh",
            .no_captures => "no captures in " ++ dir ++ " -- run tools/sameboy-frames.sh",
        };
    }
};

pub const Outcome = union(enum) {
    skipped: Skipped,
    /// A capture disagreed beyond the slack. `dumpMismatch` has already written
    /// ours, theirs, and a diff for it.
    mismatch: struct { kind: []const u8, secs: usize, differing: usize },
    matched: Summary,
};

/// Run the whole SameBoy comparison and report what happened.
///
/// Callable from both the test and the gate, which is the point: the test
/// asserts the bounds, the gate prints the numbers, and neither has to be a
/// copy of the other.
pub fn compare(io: std.Io, allocator: std.mem.Allocator) !Outcome {
    const rom = try configuredRom(io, allocator) orelse return .{ .skipped = .no_rom };
    const boot = try loadFile(io, allocator, boot_path) orelse return .{ .skipped = .no_boot_rom };

    const groups = .{ .{ "still", false }, .{ "start", true } };

    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(allocator);
    inline for (groups) |g| {
        for (if (g[1]) &start_captures else &still_captures) |secs| {
            const bytes = try captureBytes(io, allocator, g[0], secs) orelse continue;
            try collectColours(allocator, bytes, &seen);
        }
    }
    if (seen.items.len == 0) return .{ .skipped = .no_captures };
    const palette = try paletteFrom(seen.items);

    var sum: Summary = .{
        .compared = 0,
        .in_play = 0,
        .avg_masked = 0,
        .strict_total = 0,
        .strict_frames = 0,
        .still_strict = 0,
    };
    var masked_total: usize = 0;

    inline for (groups) |g| {
        for (if (g[1]) &start_captures else &still_captures) |secs| {
            const bytes = try captureBytes(io, allocator, g[0], secs) orelse continue;
            const want = try readBmp(bytes, palette);
            const ours = try captureBooted(allocator, rom, boot, secs, g[1]);
            const d = ours.differing(want);
            if (d != 0) {
                try dumpMismatch(io, allocator, g[0], secs, ours, want);
                return .{ .mismatch = .{ .kind = g[0], .secs = secs, .differing = d } };
            }
            sum.compared += 1;
            sum.in_play += @intFromBool(g[1]);
            masked_total += ours.masked();
            const strict = ours.strictDiffering(want);
            sum.strict_total += strict;
            sum.strict_frames += @intFromBool(strict != 0);
            if (!g[1]) sum.still_strict += strict;
        }
    }
    sum.avg_masked = if (sum.compared == 0) 0 else masked_total / sum.compared;
    return .{ .matched = sum };
}

test "our frames are pixel-identical to SameBoy's, on the title screen and in play" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const outcome = try compare(testing.io, arena);
    switch (outcome) {
        // The ROM, the boot ROM, and the captures are all untracked by design,
        // so a machine without them skips rather than fails. The gate says the
        // same thing in its own output, where a skipped check is visible.
        .skipped => return error.SkipZigTest,
        .mismatch => |m| {
            std.debug.print(
                "\n  {s} {d}s: {d} of {d} pixels differ beyond the object slack\n",
                .{ m.kind, m.secs, m.differing, ppu_mod.pixels },
            );
            return error.TestExpectedEqual;
        },
        .matched => |sum| {
            // The plan asks for the title screen and at least five gameplay screens.
            try testing.expect(sum.compared >= 6);
            try testing.expect(sum.in_play >= 5);
            // A mask that swallowed the screen would make "identical" meaningless.
            try testing.expect(sum.avg_masked * 5 < ppu_mod.pixels);
            // The slack exists for a known, bounded divergence in object placement.
            // If it ever starts absorbing more than a couple of sprites' worth, it
            // is hiding something else and should fail rather than keep passing.
            try testing.expect(sum.strict_total < 256);
            // The still captures have no divergence to excuse: nothing is moving,
            // so the slack must not be load-bearing there.
            try testing.expectEqual(@as(usize, 0), sum.still_strict);
        },
    }
}

/// On a mismatch, write ours, theirs, and a diff, so the failure is something
/// to look at rather than a number.
fn dumpMismatch(io: std.Io, allocator: std.mem.Allocator, comptime kind: []const u8, secs: usize, ours: Frame, want: Frame) !void {
    var out = std.Io.Dir.cwd().createDirPathOpen(io, dir ++ "/mismatch", .{}) catch return;
    defer out.close(io);

    var diff: [ppu_mod.pixels]u8 = undefined;
    for (&diff, ours.pixels, want.pixels, ours.obj) |*d, a, b, m| {
        d.* = if (m) 1 else if (a != b) 3 else 0;
    }
    const images = [_]struct { tag: []const u8, px: *const [ppu_mod.pixels]u8 }{
        .{ .tag = "ours", .px = &ours.pixels },
        .{ .tag = "sameboy", .px = &want.pixels },
        .{ .tag = "diff", .px = &diff },
    };
    for (images) |im| {
        const buf = try png.encodeIndexed(allocator, im.px, ppu_mod.width, ppu_mod.height, &png.dmg_palette);
        var name: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&name, kind ++ "-{d}-{s}.png", .{ secs, im.tag }) catch unreachable;
        try out.writeFile(io, .{ .sub_path = p, .data = buf });
    }
}

test "the status bar is the window at WY=136, not a scroll split at 135" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;
    const boot = try loadFile(testing.io, arena, boot_path) orelse return error.SkipZigTest;

    const ram = try arena.alloc(u8, 0x2000);
    @memset(ram, 0);
    var sys = try system.System.initWithBoot(rom, ram, boot);
    var grader: Grader = .{};
    sys.bus.video = grader.video();

    // Twenty seconds in, on the tester's schedule, the game is in a room.
    const target = 20 * 60;
    var tick: usize = 0;
    var acc: u32 = 0;
    var prev_ly: u8 = 0;
    var guard: u64 = 0;
    while (guard < 200_000_000) : (guard += 1) {
        _ = try sys.step();
        if (sys.bus.lcd.ly == 144 and prev_ly == 143 and tick >= target) break;
        prev_ly = sys.bus.lcd.ly;
        acc += 4;
        if (acc >= tick_cycles) {
            acc -= tick_cycles;
            tick += 1;
            const b = testerButtons(tick, target);
            sys.bus.setKeys(b.dpad, b.buttons);
        }
    }

    // The plan called this a "scanline-135 status bar split". Measured against
    // the running game, both halves of that need amending: there is no
    // mid-frame scroll write at all, and the boundary is 136, not 135. The bar
    // is the *window*, parked at WY=136, and its own line counter is what keeps
    // it still while the room scrolls underneath. 135 is the last line of the
    // play area, which is presumably where the figure came from; the play
    // window is therefore 160x136 and the bar is the eight lines below it.
    try testing.expect(grader.ppu.scrollSplit() == null);
    const start = grader.ppu.windowStart() orelse {
        std.debug.print("\n  the window never drew -- the status bar model is wrong\n", .{});
        return error.TestExpectedEqual;
    };
    try testing.expectEqual(@as(u8, 136), start);
    // WX=7 puts the window's first column at x=0, so the bar spans the screen.
    try testing.expectEqual(@as(u8, 7), grader.ppu.lines[start].wx);
    // And it stays put for the rest of the frame.
    for (start..ppu_mod.height) |i| try testing.expectEqual(@as(u8, 136), grader.ppu.lines[i].wy);
}
