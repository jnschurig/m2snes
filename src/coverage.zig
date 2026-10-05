//! Asset coverage: what we can read, what we cannot, and what nobody has
//! claimed (Step 5).
//!
//! The round-trip in `roundtrip.zig` answers "is what we read correct". It
//! cannot answer "how much of the game have we reached", because a class nobody
//! wrote a reader for produces no failing test - it produces silence. That
//! silence is what sinks a project at a checkpoint, when a screen turns out to
//! need a table nobody extracted. So this prints coverage as a standing number:
//! classes covered, items derived, bytes reached, and the named list of what is
//! still missing.
//!
//! Two things here are deliberately not rolled into a single percentage:
//!
//!   * **Proof level.** A class whose round-trip only confirms record framing
//!     is not the same evidence as one that repacks bitplanes. Both count as
//!     covered; the report says which is which so the total is never read
//!     without its caveat.
//!   * **Unclaimed bytes.** Most of the ROM is 6502-era code, not assets, so a
//!     low "claimed" percentage is expected and not a defect. What matters is
//!     *where* the gaps are: banks $9-$F are pure map data and must be fully
//!     claimed, and a gap appearing there is a real hole.

const std = @import("std");
const offsets = @import("offsets.zig");
const roundtrip = @import("roundtrip.zig");

pub const rom_bytes: usize = 256 * 1024;
pub const bank_count: usize = rom_bytes / offsets.bank_size;

/// What each bank holds, and whether we expect to have claimed all of it.
///
/// The `expect_full` banks are the ones whose entire contents are asset data
/// with a known layout; anywhere else, unclaimed bytes are code and the report
/// says so rather than flagging them.
pub const BankRole = struct {
    role: []const u8,
    expect_full: bool,
    /// Whether unclaimed runs in this bank are worth listing. False only for
    /// the two banks that are nothing but code: listing their 16 KiB as one
    /// run every time would bury the runs that matter. Banks 1, 3 and 4 stay
    /// listed even though they hold code, because they also hold tables, and
    /// an unextracted one would be hiding in exactly those gaps.
    list_gaps: bool = true,
};

pub const bank_roles = [bank_count]BankRole{
    .{ .role = "code: boot, main loop, physics", .expect_full = false, .list_gaps = false },
    .{ .role = "code + metasprites, item names", .expect_full = false },
    .{ .role = "code", .expect_full = false, .list_gaps = false },
    .{ .role = "code + enemy tables", .expect_full = false },
    .{ .role = "sound driver", .expect_full = false },
    .{ .role = "door scripts + title/credits graphics", .expect_full = false },
    .{ .role = "graphics: samus, enemies", .expect_full = false },
    .{ .role = "graphics: tilesets, items", .expect_full = false },
    .{ .role = "tilesets: metatiles, collision, solidity", .expect_full = false },
    .{ .role = "map data", .expect_full = true },
    .{ .role = "map data", .expect_full = true },
    .{ .role = "map data", .expect_full = true },
    .{ .role = "map data", .expect_full = true },
    .{ .role = "map data", .expect_full = true },
    .{ .role = "map data", .expect_full = true },
    .{ .role = "map data", .expect_full = true },
};

/// Asset classes later steps need that no reader covers yet. Written down
/// rather than left implicit: an enumerated gap is a work item, an unenumerated
/// one is a surprise. Steps delete entries from here as they land.
///
/// **No offsets entry is undecoded any more, and none is `pending` either.**
/// `enemy_data` left this list in Step 9 of the slice; `item_names` and
/// `samus_pose_tables` in Step 11. What is left is three classes nothing has
/// looked for yet, each with the step that will need it.
pub const not_yet_decoded = [_]struct {
    name: []const u8,
    why: []const u8,
    needed_by: []const u8,
}{
    .{
        .name = "physics_constants",
        .why = "scattered as immediates through bank 0 rather than gathered in a table",
        .needed_by = "Step 13 (Samus movement)",
    },
    .{
        .name = "title_tilemap",
        .why = "included in bank 5 without an address comment; a ROM search or a build-and-map pass will pin it",
        .needed_by = "Step 12 (boot and screen rendering)",
    },
    .{
        .name = "audio sequence data and instrument definitions",
        .why = "the sound driver's data layout is unread; only its three entry trampolines are catalogued",
        .needed_by = "Step 17 (TAD emitter)",
    },
};

/// One unclaimed run, already split at bank boundaries so it has a single
/// bank and a single GB address.
pub const Gap = struct {
    bank: u8,
    gb_addr: u16,
    size: usize,

    pub fn romOffset(self: Gap) usize {
        return @as(usize, self.bank) * offsets.bank_size + (self.gb_addr & 0x3FFF);
    }
};

pub const KindRow = struct {
    kind: offsets.Kind,
    proof: roundtrip.Proof,
    entries: usize = 0,
    items: usize = 0,
    bytes: usize = 0,
    failed: usize = 0,
    unit: []const u8 = "-",
};

pub const Summary = struct {
    rows: []KindRow,
    gaps: []Gap,
    claimed: [bank_count]usize,
    claimed_total: usize = 0,
    /// Bytes in banks the roles table says should be fully claimed but are not.
    /// Any nonzero value is a hole in data we thought we had mapped.
    unclaimed_in_full_banks: usize = 0,
    entries: usize = 0,
    items: usize = 0,
    failed: usize = 0,
    undecoded_entries: usize = 0,
    undecoded_bytes: usize = 0,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        allocator.free(self.gaps);
    }

    pub fn ok(self: Summary) bool {
        return self.failed == 0 and self.unclaimed_in_full_banks == 0;
    }
};

fn lessByOffset(_: void, a: offsets.Entry, b: offsets.Entry) bool {
    return a.romOffset() < b.romOffset();
}

/// Aggregate a round-trip report into per-kind rows, and walk the ROM for runs
/// no entry claims.
pub fn summarize(allocator: std.mem.Allocator, report: roundtrip.Report) !Summary {
    const kind_fields = @typeInfo(offsets.Kind).@"enum".fields;
    var rows = try allocator.alloc(KindRow, kind_fields.len);
    errdefer allocator.free(rows);
    inline for (kind_fields, 0..) |f, i| {
        const k = @field(offsets.Kind, f.name);
        rows[i] = .{ .kind = k, .proof = roundtrip.plan(k).proof };
    }

    var s: Summary = .{ .rows = rows, .gaps = &.{}, .claimed = @splat(0) };

    for (report.results.items) |r| {
        const row = &rows[@intFromEnum(r.kind)];
        row.entries += 1;
        row.items += r.items;
        row.bytes += r.bytes;
        if (!r.ok) row.failed += 1;
        if (!std.mem.eql(u8, r.unit, "-")) row.unit = r.unit;

        s.entries += 1;
        s.items += r.items;
        if (!r.ok) s.failed += 1;
        if (r.proof == .none) {
            s.undecoded_entries += 1;
            s.undecoded_bytes += r.bytes;
        }
    }

    // ---- Unclaimed runs ---------------------------------------------------
    const sorted = try allocator.dupe(offsets.Entry, &offsets.entries);
    defer allocator.free(sorted);
    std.mem.sort(offsets.Entry, sorted, {}, lessByOffset);

    var gaps: std.ArrayList(Gap) = .empty;
    errdefer gaps.deinit(allocator);

    var cursor: usize = 0;
    for (sorted) |e| {
        if (e.romOffset() > cursor) try appendGap(allocator, &gaps, cursor, e.romOffset());
        cursor = @max(cursor, e.romEnd());
        s.claimed[e.bank] += e.size;
        s.claimed_total += e.size;
    }
    if (cursor < rom_bytes) try appendGap(allocator, &gaps, cursor, rom_bytes);

    for (gaps.items) |g| {
        if (bank_roles[g.bank].expect_full) s.unclaimed_in_full_banks += g.size;
    }

    s.gaps = try gaps.toOwnedSlice(allocator);
    return s;
}

/// Split one unclaimed run at bank boundaries so every gap has one bank.
fn appendGap(allocator: std.mem.Allocator, gaps: *std.ArrayList(Gap), from: usize, to: usize) !void {
    var at = from;
    while (at < to) {
        const bank: u8 = @intCast(at / offsets.bank_size);
        const bank_end = (@as(usize, bank) + 1) * offsets.bank_size;
        const end = @min(to, bank_end);
        const within: u16 = @intCast(at % offsets.bank_size);
        try gaps.append(allocator, .{
            .bank = bank,
            .gb_addr = if (bank == 0) within else within + 0x4000,
            .size = end - at,
        });
        at = end;
    }
}

/// The full report, as text. Written to `extracted/coverage.txt` and echoed in
/// summary form by `zig build verify`.
pub fn render(allocator: std.mem.Allocator, report: roundtrip.Report, s: Summary) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\=== Metroid II asset coverage ===
        \\
        \\Round-trip: every class below is decoded into its typed form and
        \\re-serialised from that form alone; the result must equal the ROM bytes
        \\it came from. "proof" is what passing demonstrates:
        \\
        \\  encoding  bytes are reconstructed, not copied - bitplanes repacked,
        \\            terminators re-emitted, opcode streams rebuilt
        \\  framing   records are re-serialised field by field, but the field
        \\            values ride through verbatim: stride, count, order and
        \\            endianness are proven, meaning is not
        \\  raw       no decoder exists; nothing is proven and the class is
        \\            named under "still missing" below
        \\
        \\
    );

    try buf.print(allocator, "{s:<24} {s:>7} {s:>8} {s:>9} {s:>9}  {s}\n", .{
        "class", "entries", "items", "bytes", "proof", "status",
    });
    for (s.rows) |row| {
        if (row.entries == 0) continue;
        try buf.print(allocator, "{s:<24} {d:>7} {d:>8} {d:>9} {s:>9}  {s}\n", .{
            @tagName(row.kind),
            row.entries,
            row.items,
            row.bytes,
            row.proof.label(),
            if (row.proof == .none) "not decoded" else if (row.failed == 0) "round-trips" else "FAILED",
        });
    }
    try buf.print(allocator, "{s:<24} {d:>7} {d:>8} {d:>9}\n", .{
        "TOTAL", s.entries, s.items, s.claimed_total,
    });

    try buf.print(allocator,
        \\
        \\{d} of {d} entries carry a decoder; {d} bytes round-trip byte-for-byte,
        \\{d} bytes are dumped raw. {d} round-trip failures.
        \\
        \\What each class's round-trip actually proves:
        \\
    , .{
        report.checked,      offsets.entries.len, report.bytes_round_tripped,
        report.bytes_undecoded, report.failed,
    });
    for (s.rows) |row| {
        if (row.entries == 0) continue;
        try buf.print(allocator, "  {s:<22} {s}\n", .{ @tagName(row.kind), roundtrip.plan(row.kind).claim });
    }

    // The gate prints only the first few failures; this is where the rest go,
    // so "full list in coverage.txt" is a promise the file actually keeps.
    if (report.failed != 0) {
        try buf.print(allocator, "\n--- Round-trip failures ({d}) ---\n\n", .{report.failed});
        for (report.results.items) |r| {
            if (r.ok) continue;
            if (r.err) |e| {
                try buf.print(allocator, "  {s} ({s}): decoder refused the bytes ({s})\n", .{ r.name, @tagName(r.kind), e });
            } else {
                try buf.print(allocator, "  {s} ({s}): first difference at +${x}, {d} bytes in vs {d} out\n", .{
                    r.name, @tagName(r.kind), r.first_diff orelse 0, r.bytes, r.encoded_len,
                });
            }
        }
    }

    // ---- Bytes reached ----------------------------------------------------
    try buf.print(allocator,
        \\
        \\--- ROM coverage by bank ---
        \\
        \\{d} of {d} bytes claimed ({d}.{d:0>1}%). Most of the remainder is code:
        \\only the banks marked "all" are expected to be fully claimed.
        \\
        \\
    , .{
        s.claimed_total, rom_bytes,
        s.claimed_total * 100 / rom_bytes,
        (s.claimed_total * 1000 / rom_bytes) % 10,
    });
    try buf.print(allocator, "{s:>4} {s:>8} {s:>7} {s:>5}  {s}\n", .{ "bank", "claimed", "of", "", "role" });
    for (s.claimed, 0..) |c, i| {
        try buf.print(allocator, "  ${X:0>1} {d:>8} {d:>7} {s:>5}  {s}\n", .{
            i, c, offsets.bank_size,
            if (bank_roles[i].expect_full) "all" else "",
            bank_roles[i].role,
        });
    }

    // ---- Unclaimed runs ---------------------------------------------------
    var unclaimed_total: usize = 0;
    for (s.gaps) |g| unclaimed_total += g.size;
    try buf.print(allocator,
        \\
        \\--- Unclaimed runs ({d} runs, {d} bytes) ---
        \\
        \\Runs of 64 bytes or more, excluding banks $0 and $2, which are nothing
        \\but code. A run here is not necessarily a defect - bank 5 keeps
        \\freespace, bank 4 is the sound driver's code, and banks 1/3 interleave
        \\code with their tables - but it is where an unextracted table would be
        \\hiding, so they are listed rather than summed away.
        \\
        \\
    , .{ s.gaps.len, unclaimed_total });
    var listed: usize = 0;
    for (s.gaps) |g| {
        if (!bank_roles[g.bank].list_gaps) continue;
        if (g.size < 64) continue;
        try buf.print(allocator, "  bank ${X:0>1} ${X:0>4}  {d:>6} bytes{s}\n", .{
            g.bank, g.gb_addr, g.size,
            if (bank_roles[g.bank].expect_full) "   <- in a bank that should be fully claimed" else "",
        });
        listed += 1;
    }
    if (listed == 0) try buf.appendSlice(allocator, "  (none)\n");
    try buf.print(allocator, "\n  {d} bytes unclaimed in banks that should be fully claimed.\n", .{
        s.unclaimed_in_full_banks,
    });

    // ---- Still missing ----------------------------------------------------
    try buf.appendSlice(allocator,
        \\
        \\--- Still missing ---
        \\
        \\Named, not implied. Each line is a work item with the step that needs it.
        \\
        \\
    );
    for (not_yet_decoded) |m| {
        try buf.print(allocator, "  {s}\n      {s}\n      needed by: {s}\n", .{ m.name, m.why, m.needed_by });
    }
    try buf.print(allocator, "\n  {d} offsets entries are still `pending` - catalogued as unknown rather than guessed:\n", .{offsets.pending.len});
    for (offsets.pending) |p| {
        try buf.print(allocator, "    {s}: {s}\n", .{ p.name, p.why });
    }

    return buf.toOwnedSlice(allocator);
}

/// Where `zig build verify` and `zig build coverage` both write the report.
pub const file_name = "coverage.txt";

/// Round-trip, summarise, and render in one call, for callers that only want
/// the text. The two-step form stays public because `verify` needs the
/// structured result to decide whether to fail.
pub fn reportText(allocator: std.mem.Allocator, rom: []const u8) ![]u8 {
    var report = try roundtrip.run(allocator, rom);
    defer report.deinit(allocator);
    var s = try summarize(allocator, report);
    defer s.deinit(allocator);
    return render(allocator, report, s);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "the bank roles table covers the whole ROM and marks the map banks full" {
    try testing.expectEqual(@as(usize, 16), bank_roles.len);
    for (0..bank_count) |i| {
        try testing.expect(bank_roles[i].role.len != 0);
        try testing.expectEqual(i >= 9, bank_roles[i].expect_full);
        // Only the two pure-code banks are exempt from gap listing, and a bank
        // we expect to be fully claimed can never be: a gap there is the one
        // coverage finding that is a gate.
        try testing.expectEqual(i != 0 and i != 2, bank_roles[i].list_gaps);
        if (bank_roles[i].expect_full) try testing.expect(bank_roles[i].list_gaps);
    }
}

test "gaps split at bank boundaries and carry the right GB address" {
    const gpa = testing.allocator;
    var gaps: std.ArrayList(Gap) = .empty;
    defer gaps.deinit(gpa);

    // A run straddling the bank 1 / bank 2 boundary.
    try appendGap(gpa, &gaps, offsets.bank_size * 2 - 16, offsets.bank_size * 2 + 32);
    try testing.expectEqual(@as(usize, 2), gaps.items.len);
    try testing.expectEqual(@as(u8, 1), gaps.items[0].bank);
    try testing.expectEqual(@as(u16, 0x7FF0), gaps.items[0].gb_addr);
    try testing.expectEqual(@as(usize, 16), gaps.items[0].size);
    try testing.expectEqual(@as(u8, 2), gaps.items[1].bank);
    try testing.expectEqual(@as(u16, 0x4000), gaps.items[1].gb_addr);
    try testing.expectEqual(@as(usize, 32), gaps.items[1].size);
    // The round trip back to a flat offset must land where the run started.
    try testing.expectEqual(offsets.bank_size * 2 - 16, gaps.items[0].romOffset());

    // Bank 0 is not paged, so its addresses stay below $4000.
    gaps.clearRetainingCapacity();
    try appendGap(gpa, &gaps, 0x100, 0x180);
    try testing.expectEqual(@as(u16, 0x100), gaps.items[0].gb_addr);
}

test "every missing-class entry names a why and a step that needs it" {
    for (not_yet_decoded) |m| {
        try testing.expect(m.name.len != 0);
        try testing.expect(m.why.len != 0);
        try testing.expect(m.needed_by.len != 0);
    }
    // Every undecoded offsets kind must be named here, or the report would show
    // "not decoded" for a class the missing list never mentions - and no
    // *decoded* one may be, or the list would keep asking for work that is
    // done. Derived from `roundtrip.plan` rather than restated, which is what
    // makes Step 9's removal of `enemy_data` checkable rather than trusted.
    inline for (@typeInfo(offsets.Kind).@"enum".fields) |f| {
        const kind = @field(offsets.Kind, f.name);
        var named = false;
        for (not_yet_decoded) |m| {
            // The entry's first word, so `physics_constants` is not read as the
            // `physics` kind - it is a different thing that shares a prefix.
            const head = m.name[0 .. std.mem.indexOfScalar(u8, m.name, ' ') orelse m.name.len];
            if (std.mem.eql(u8, head, f.name)) named = true;
        }
        try testing.expectEqual(roundtrip.plan(kind).proof == .none, named);
    }
    // And every `pending` offsets class too.
    for (offsets.pending) |p| {
        var seen = false;
        for (not_yet_decoded) |m| {
            if (std.mem.startsWith(u8, m.name, p.name)) seen = true;
        }
        try testing.expect(seen);
    }
}

// ---- ROM-dependent --------------------------------------------------------

const testrom = @import("testrom");

test "banks $9-$F are fully claimed, and the summary agrees with the entries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rom = try testrom.load(arena) orelse return error.SkipZigTest;

    var report = try roundtrip.run(testing.allocator, rom);
    defer report.deinit(testing.allocator);
    var s = try summarize(testing.allocator, report);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), s.unclaimed_in_full_banks);
    for (9..bank_count) |b| try testing.expectEqual(offsets.bank_size, s.claimed[b]);

    // Claimed bytes must equal the sum of the entry sizes; a double-counted
    // entry would inflate coverage without any test noticing.
    var sum: usize = 0;
    for (offsets.entries) |e| sum += e.size;
    try testing.expectEqual(sum, s.claimed_total);
    try testing.expectEqual(offsets.entries.len, s.entries);

    // Gaps plus claimed bytes must account for the whole ROM exactly.
    var gap_bytes: usize = 0;
    for (s.gaps) |g| gap_bytes += g.size;
    try testing.expectEqual(rom_bytes, gap_bytes + s.claimed_total);
}
