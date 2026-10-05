//! The request-site ledger: every place the Game Boy asks for a sound, and
//! what the port does about each one (metroid2-audio Step 16a).
//!
//! **Why this exists.** `audioparity` grades the cart's requests against the
//! original's, but only over the frames the port can already play. A routine
//! ported later, into a room no graded stretch reaches, could arrive with its
//! sound missing and nothing would fail. This closes that: the sites come from
//! the ROM, the port says which it sends, and a site in code the port has
//! plainly ported but doesn't send fails the test.
//!
//! **The sites are read from the ROM, not the disassembly.** A site is a
//! store to one of the request bytes in `audio_req.slots` (`audiocost`'s scan),
//! or a `CALL silenceAudio_longJump` (`CD 90 23`), anywhere in the code banks
//! except bank 4, the sound driver itself. M2RoS agrees bank
//! by bank (checked below), which is how we know no data byte is posing as one.
//!
//! **The port names its sites.** Every `%audio_put(slot, $BBAAAA...)` in
//! `engine/main.asm` lists the Game Boy site it stands for. A site is then:
//!
//!   * `sent`: a put names it, with the same slot.
//!   * `waived`: in `waivers` below, with the reason the port does not send it.
//!   * `missing`: neither, but the port has the code around it: the site is
//!     in the body of a routine `ledger.known` calls converted or partial, or
//!     the port cites a Game Boy address within a few bytes of it. **This
//!     fails.**
//!   * `unported`: none of the above. The routine is still to come.
//!
//! Banks 1, 2, 3 and 5 all sit at $4000-$7FFF, so a bare `$AAAA` citation
//! takes the bank of the bank-qualified citation before it (`citations`). A
//! wrong guess errs towards `missing`, which a waiver answers with its reason;
//! it never lets a ported site through silently.

const std = @import("std");
const audio_req = @import("audio_req.zig");
const disasm = @import("gb/disasm.zig");
const audiocost = @import("audiocost.zig");
const ledger = @import("ledger.zig");

/// The banks a site can be in: the code banks (`ledger.code_banks`) less bank
/// 4, whose own writes are the driver's.
pub const site_banks = [_]u8{ 0, 1, 2, 3, 5 };

/// How far before and after a site a port citation counts as "this code is
/// ported". A site is `LD A,d8` + `LD (a16),A`, five bytes, and the port cites
/// every few instructions, so eight back and four on reaches the instruction
/// before the pair and the one after it.
pub const cite_before: u16 = 8;
pub const cite_after: u16 = 4;

pub const Site = struct {
    bank: u8,
    addr: u16,
    slot: u8,
    /// The byte stored, when the instruction before is `LD A,d8` or `XOR A`.
    value: ?u8,

    pub fn id(self: Site) u24 {
        return @as(u24, self.bank) << 16 | self.addr;
    }
};

/// 00:$2390 `silenceAudio_longJump`, the call the game makes; the same address
/// `audio_parity` watches for slot 12.
pub const silence_long_jump: u16 = 0x2390;

pub fn bankBase(bank: u8) u16 {
    return if (bank == 0) 0 else 0x4000;
}

/// Every site in the ROM, in bank then address order. The request stores are
/// `audiocost.requestSites`, the scan Step 3 already checks; this adds the two
/// kinds it has no reason to list: stores to `songInterruptionPlaying` (the
/// set slot) and calls to `silenceAudio_longJump`.
pub fn scan(gpa: std.mem.Allocator, rom: []const u8) ![]Site {
    var out: std.ArrayList(Site) = .empty;
    for (try audiocost.requestSites(gpa, rom)) |r| {
        if (std.mem.indexOfScalar(u8, &site_banks, r.bank) == null) continue;
        try out.append(gpa, .{ .bank = r.bank, .addr = r.addr, .slot = storeSlot(r.target).?, .value = r.id orelse xorValue(rom, r.bank, r.addr) });
    }
    const set_slot = audio_req.slotByName("songInterruptionPlaying").?;
    const call_slot = audio_req.slotByName("silenceAudio").?;
    for (site_banks) |bank| {
        const start = @as(usize, bank) * 0x4000;
        const code = rom[start .. start + 0x4000];
        var i: usize = 0;
        while (i + 3 <= code.len) : (i += 1) {
            const target = @as(u16, code[i + 1]) | @as(u16, code[i + 2]) << 8;
            const addr = bankBase(bank) + @as(u16, @intCast(i));
            if (code[i] == 0xEA and target == audio_req.slots[set_slot].wram) {
                const v: ?u8 = if (i >= 2 and code[i - 2] == 0x3E) code[i - 1] else xorValue(rom, bank, addr);
                try out.append(gpa, .{ .bank = bank, .addr = addr, .slot = set_slot, .value = v });
            } else if (code[i] == 0xCD and target == silence_long_jump) {
                try out.append(gpa, .{ .bank = bank, .addr = addr, .slot = call_slot, .value = null });
            }
        }
    }
    std.mem.sort(Site, out.items, {}, struct {
        fn lt(_: void, a: Site, b: Site) bool {
            return a.id() < b.id();
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

fn storeSlot(target: u16) ?u8 {
    for (audio_req.slots, 0..) |s, i| {
        if ((s.kind == .request or s.kind == .set) and s.wram == target) return @intCast(i);
    }
    return null;
}

/// Zero when the instruction before the store is `XOR A`.
fn xorValue(rom: []const u8, bank: u8, addr: u16) ?u8 {
    const off = @as(usize, bank) * 0x4000 + (addr - bankBase(bank));
    return if (off >= 1 and rom[off - 1] == 0xAF) 0 else null;
}

/// One `%audio_put` in the port.
pub const Put = struct {
    line: usize,
    slot: u8,
    sites: []const u24,
};

pub const ParseError = error{ UnknownSlot, NoSite, BadSite };

/// Every `%audio_put`, `%audio_put_long`, `%audio_put_zero` and
/// `%audio_request` in the engine's source.
pub fn parsePuts(gpa: std.mem.Allocator, src: []const u8) ![]Put {
    var out: std.ArrayList(Put) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        // An anonymous label (`+`, `--`) may stand in front of the macro.
        const line = std.mem.trimStart(u8, std.mem.trim(u8, raw, " \t\r"), "+- \t");
        // `%audio_request` carries the value between the slot and the sites.
        var has_value = false;
        const rest = if (std.mem.startsWith(u8, line, "%audio_put_zero("))
            line["%audio_put_zero(".len..]
        else if (std.mem.startsWith(u8, line, "%audio_put_long("))
            line["%audio_put_long(".len..]
        else if (std.mem.startsWith(u8, line, "%audio_put("))
            line["%audio_put(".len..]
        else if (std.mem.startsWith(u8, line, "%audio_request(")) blk: {
            has_value = true;
            break :blk line["%audio_request(".len..];
        } else continue;
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse return error.BadSite;
        var args = std.mem.tokenizeAny(u8, rest[0..close], ", ");
        const eq = args.next() orelse return error.UnknownSlot;
        const slot = equateSlot(eq) orelse return error.UnknownSlot;
        if (has_value) _ = args.next() orelse return error.NoSite;
        var sites: std.ArrayList(u24) = .empty;
        while (args.next()) |a| {
            if (a.len != 7 or a[0] != '$') return error.BadSite;
            try sites.append(gpa, std.fmt.parseInt(u24, a[1..], 16) catch return error.BadSite);
        }
        if (sites.items.len == 0) return error.NoSite;
        try out.append(gpa, .{ .line = n, .slot = slot, .sites = try sites.toOwnedSlice(gpa) });
    }
    return out.toOwnedSlice(gpa);
}

fn equateSlot(eq: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, eq, "!")) return null;
    for (audio_req.slots, 0..) |s, i| {
        if (std.mem.eql(u8, s.equate, eq[1..])) return @intCast(i);
    }
    return null;
}

/// Every Game Boy address the source cites, as `bank << 16 | address`: a `$`
/// and four hex digits, not followed by a fifth. `BB:$AAAA` names its bank;
/// a bare `$AAAA` under $4000 is bank 0's, and one at or above it is the bank
/// of the nearest bank-qualified citation before it -- the bank the routine it
/// sits in is headed with. Before any, it is taken as every banked bank's.
pub fn citations(gpa: std.mem.Allocator, src: []const u8) !std.AutoHashMapUnmanaged(u24, void) {
    var set: std.AutoHashMapUnmanaged(u24, void) = .empty;
    var bank: ?u8 = null;
    var i: usize = 0;
    while (i + 5 <= src.len) : (i += 1) {
        if (src[i] != '$') continue;
        const d = src[i + 1 .. i + 5];
        const all_hex = for (d) |c| {
            if (!std.ascii.isHex(c)) break false;
        } else true;
        if (!all_hex) continue;
        if (i + 5 < src.len and std.ascii.isHex(src[i + 5])) continue;
        const addr = std.fmt.parseInt(u16, d, 16) catch unreachable;
        if (i >= 3 and src[i - 1] == ':' and std.ascii.isHex(src[i - 2]) and std.ascii.isHex(src[i - 3]) and
            (i == 3 or !std.ascii.isAlphanumeric(src[i - 4])))
        {
            bank = std.fmt.parseInt(u8, src[i - 3 .. i - 1], 16) catch unreachable;
        }
        if (addr < 0x4000) {
            try set.put(gpa, addr, {});
        } else if (bank) |bk| {
            try set.put(gpa, @as(u24, bk) << 16 | addr, {});
        } else for (site_banks[1..]) |bk| {
            try set.put(gpa, @as(u24, bk) << 16 | addr, {});
        }
    }
    return set;
}

/// A Game Boy address the port says it has ported: a converted or partial
/// `ledger.known` routine, or a bank-qualified citation (`00:$13B7`) in the
/// engine's source, which is how `engine/main.asm` heads each routine it
/// ports and marks the branches inside it.
pub const Claim = struct { bank: u8, addr: u16, name: []const u8 };

/// Every bank-qualified citation in the source, `BB:$AAAA` or `BB:AAAA`.
pub fn bankCitations(gpa: std.mem.Allocator, src: []const u8) ![]Claim {
    var out: std.ArrayList(Claim) = .empty;
    var i: usize = 0;
    while (i + 7 <= src.len) : (i += 1) {
        if (src[i + 2] != ':') continue;
        if (i > 0 and (std.ascii.isAlphanumeric(src[i - 1]) or src[i - 1] == '$')) continue;
        const bank = std.fmt.parseInt(u8, src[i .. i + 2], 16) catch continue;
        var j = i + 3;
        if (src[j] == '$') j += 1;
        if (j + 4 > src.len) continue;
        const addr = std.fmt.parseInt(u16, src[j .. j + 4], 16) catch continue;
        if (j + 4 < src.len and std.ascii.isHex(src[j + 4])) continue;
        if (std.mem.indexOfScalar(u8, &site_banks, bank) == null) continue;
        if (addr < bankBase(bank) or addr >= bankBase(bank) + 0x4000) continue;
        try out.append(gpa, .{ .bank = bank, .addr = addr, .name = "cited" });
    }
    return out.toOwnedSlice(gpa);
}

/// Which bytes of a bank's window the port's routines own, walked from each
/// claim. The walk follows branches and jumps within the window, steps over
/// calls, and stops at a return, an indirect jump, and any other claim, so a
/// shared tail is its own routine's (`ledger`'s tail-call rule) and a callee is
/// not swallowed into its caller. Names are per byte, null where no claim
/// reaches.
pub fn portedBodies(gpa: std.mem.Allocator, rom: []const u8, bank: u8, cls: []const Claim) ![]?[]const u8 {
    const base = bankBase(bank);
    const start = @as(usize, bank) * 0x4000;
    const code = rom[start .. start + 0x4000];
    const owner = try gpa.alloc(?[]const u8, code.len);
    @memset(owner, null);
    const entry = try gpa.alloc(bool, code.len);
    @memset(entry, false);
    for (cls) |c| {
        if (c.bank == bank) entry[c.addr - base] = true;
    }
    const seen = try gpa.alloc(bool, code.len);
    var work: std.ArrayList(u16) = .empty;
    for (cls) |c| {
        if (c.bank != bank) continue;
        @memset(seen, false);
        work.clearRetainingCapacity();
        try work.append(gpa, c.addr);
        while (work.pop()) |addr| {
            if (addr < base or addr - base >= code.len) continue;
            const off = addr - base;
            if (seen[off]) continue;
            if (addr != c.addr and entry[off]) continue;
            seen[off] = true;
            const insn = disasm.decode(code[off..], addr);
            for (0..insn.len) |i| {
                if (off + i < code.len and owner[off + i] == null) owner[off + i] = c.name;
            }
            const next = addr +% insn.len;
            switch (insn.flow) {
                .next, .call, .call_cc, .ret_cc => try work.append(gpa, next),
                .jump => |t| try work.append(gpa, t),
                .branch => |t| {
                    try work.append(gpa, t);
                    try work.append(gpa, next);
                },
                .ret, .indirect, .stop, .illegal => {},
            }
        }
    }
    return owner;
}

/// The claims: `ledger.known`'s converted and partial routines, then the
/// source's bank-qualified citations.
pub fn claims(gpa: std.mem.Allocator, src: []const u8) ![]Claim {
    var out: std.ArrayList(Claim) = .empty;
    for (ledger.known) |k| {
        if (k.status == .unconverted) continue;
        try out.append(gpa, .{ .bank = k.bank, .addr = k.addr, .name = k.name });
    }
    try out.appendSlice(gpa, try bankCitations(gpa, src));
    return out.toOwnedSlice(gpa);
}

/// A site `missing` would flag that the port does not send, and why: code the
/// port doesn't have after all (a claim that reached it through data, or an
/// arm of a routine the port has the rest of), or a later step's.
pub const Waiver = struct {
    site: u24,
    /// For code not yet ported, the entry of the Game Boy routine it is in,
    /// where the port does not already cite it. Once the port does -- a
    /// bank-qualified citation, or an AI table's `dw $AAAA` for bank 2 -- the
    /// routine has arrived and the waiver is stale.
    entry: ?u24 = null,
    why: []const u8,
};

pub const waivers = [_]Waiver{};

pub const Status = enum { sent, waived, missing, unported };

pub const Row = struct {
    site: Site,
    status: Status,
    /// The put's line in `engine/main.asm`, for `sent`.
    line: usize = 0,
    /// The ported routine whose body holds the site, if any.
    routine: ?[]const u8 = null,
    why: []const u8 = "",
};

pub const Problem = union(enum) {
    /// A put names a site the ROM does not have.
    no_such_site: struct { line: usize, site: u24 },
    /// A put's slot is not the site's.
    wrong_slot: struct { line: usize, site: u24 },
    /// Two puts name the same site.
    sent_twice: struct { line: usize, site: u24 },
    /// A waiver for a site that is sent, that does not exist, or whose
    /// routine the port now claims.
    stale_waiver: u24,
};

pub const Ledger = struct {
    rows: []Row,
    problems: []Problem,

    pub fn count(self: Ledger, s: Status) usize {
        var n: usize = 0;
        for (self.rows) |r| n += @intFromBool(r.status == s);
        return n;
    }
};

/// Whether the port claims a Game Boy routine entry: a claim at exactly that
/// address, or, in bank 2, an AI dispatch table's `dw $AAAA : dw`.
fn claimed(src: []const u8, cls: []const Claim, entry: u24) bool {
    for (cls) |c| {
        if ((@as(u24, c.bank) << 16 | c.addr) == entry) return true;
    }
    if (entry >> 16 != 2) return false;
    var buf: [16]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "dw ${X:0>4} : dw", .{@as(u16, @truncate(entry))}) catch unreachable;
    return std.mem.indexOf(u8, src, pat) != null;
}

/// `owners` is `portedBodies` per bank in `site_banks` order, or empty; `cls`
/// the claims they were walked from.
pub fn classify(gpa: std.mem.Allocator, sites: []const Site, puts: []const Put, src: []const u8, ws: []const Waiver, owners: []const []const ?[]const u8, cls: []const Claim) !Ledger {
    var cited = try citations(gpa, src);
    var problems: std.ArrayList(Problem) = .empty;
    const rows = try gpa.alloc(Row, sites.len);
    for (sites, rows) |s, *r| {
        r.* = .{ .site = s, .status = .unported };
        if (owners.len == 0) continue;
        const b = std.mem.indexOfScalar(u8, &site_banks, s.bank).?;
        r.routine = owners[b][s.addr - bankBase(s.bank)];
    }

    for (puts) |p| {
        for (p.sites) |id| {
            const r = for (rows) |*r| {
                if (r.site.id() == id) break r;
            } else {
                try problems.append(gpa, .{ .no_such_site = .{ .line = p.line, .site = id } });
                continue;
            };
            if (r.site.slot != p.slot) try problems.append(gpa, .{ .wrong_slot = .{ .line = p.line, .site = id } });
            if (r.status == .sent) try problems.append(gpa, .{ .sent_twice = .{ .line = p.line, .site = id } });
            r.status = .sent;
            r.line = p.line;
        }
    }
    for (ws) |w| {
        const r = for (rows) |*r| {
            if (r.site.id() == w.site) break r;
        } else {
            try problems.append(gpa, .{ .stale_waiver = w.site });
            continue;
        };
        if (r.status == .sent or (w.entry != null and claimed(src, cls, w.entry.?))) {
            try problems.append(gpa, .{ .stale_waiver = w.site });
            continue;
        }
        r.status = .waived;
        r.why = w.why;
    }
    for (rows) |*r| {
        if (r.status != .unported) continue;
        if (r.routine != null) {
            r.status = .missing;
            continue;
        }
        const lo = r.site.addr -| cite_before;
        var a = lo;
        while (a <= r.site.addr + cite_after) : (a += 1) {
            if (cited.contains(@as(u24, r.site.bank) << 16 | a)) {
                r.status = .missing;
                break;
            }
        }
    }
    return .{ .rows = rows, .problems = try problems.toOwnedSlice(gpa) };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

fn fixtureRom() [6 * 0x4000]u8 {
    var rom = [_]u8{0} ** (6 * 0x4000);
    // 00:$0100 LD A,$15 / LD ($CEC0),A -- a square 1 request.
    @memcpy(rom[0x100..0x105], &[_]u8{ 0x3E, 0x15, 0xEA, 0xC0, 0xCE });
    // 00:$0200 CALL $2390 -- silenceAudio.
    @memcpy(rom[0x200..0x203], &[_]u8{ 0xCD, 0x90, 0x23 });
    // 02:$4300 XOR A / LD ($CED5),A -- a noise request cleared.
    @memcpy(rom[0x8300..0x8304], &[_]u8{ 0xAF, 0xEA, 0xD5, 0xCE });
    // 04:$4000 LD ($CEC0),A -- bank 4 is the driver's, not a site.
    @memcpy(rom[0x10000..0x10003], &[_]u8{ 0xEA, 0xC0, 0xCE });
    // 00:$0300 LD ($CEC1),A -- a read-back byte, not a request.
    @memcpy(rom[0x300..0x303], &[_]u8{ 0xEA, 0xC1, 0xCE });
    return rom;
}

test "sites are request stores and silence calls outside bank 4" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const rom = fixtureRom();
    const sites = try scan(arena_state.allocator(), &rom);
    try testing.expectEqual(@as(usize, 3), sites.len);
    try testing.expectEqual(@as(u24, 0x000102), sites[0].id());
    try testing.expectEqual(@as(?u8, 0x15), sites[0].value);
    try testing.expectEqual(audio_req.slotByName("silenceAudio").?, sites[1].slot);
    try testing.expectEqual(@as(u24, 0x024301), sites[2].id());
    try testing.expectEqual(@as(?u8, 0), sites[2].value);
}

test "a site is sent, waived, missing or unported, and each mistake is named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rom = fixtureRom();
    const sites = try scan(a, &rom);

    // Nothing cited: all three still to come.
    var l = try classify(a, sites, &.{}, "", &.{}, &.{}, &.{});
    try testing.expectEqual(@as(usize, 3), l.count(.unported));

    // The code around the first and third is cited; only the first is sent.
    const src =
        \\        lda.b #$15              ; $0100
        \\        sta.w !Sfx1
        \\        %audio_put(!REQ_SFX_SQUARE1, $000102)
        \\        stz.w !SfxNoise         ; $4301
    ;
    const puts = try parsePuts(a, src);
    try testing.expectEqual(@as(usize, 1), puts.len);
    try testing.expectEqual(@as(usize, 3), puts[0].line);
    l = try classify(a, sites, puts, src, &.{}, &.{}, &.{});
    try testing.expectEqual(Status.sent, l.rows[0].status);
    try testing.expectEqual(Status.unported, l.rows[1].status);
    try testing.expectEqual(Status.missing, l.rows[2].status);
    try testing.expectEqual(@as(usize, 0), l.problems.len);

    // A waiver answers the missing one; a waiver for a sent site is stale.
    l = try classify(a, sites, puts, src, &.{
        .{ .site = 0x024301, .why = "test" },
        .{ .site = 0x000102, .why = "test" },
    }, &.{}, &.{});
    try testing.expectEqual(Status.waived, l.rows[2].status);
    try testing.expectEqual(@as(usize, 1), l.problems.len);
    try testing.expect(l.problems[0] == .stale_waiver);

    // The wrong slot, a site that isn't one, and a site sent twice.
    const bad =
        \\        %audio_put(!REQ_SFX_NOISE, $000102)
        \\        %audio_put_zero(!REQ_SFX_NOISE, $000103, $024301)
        \\        %audio_request(!REQ_SFX_NOISE, $02, $024301)
    ;
    l = try classify(a, sites, try parsePuts(a, bad), bad, &.{}, &.{}, &.{});
    try testing.expectEqual(@as(usize, 3), l.problems.len);
    try testing.expect(l.problems[0] == .wrong_slot);
    try testing.expect(l.problems[1] == .no_such_site);
    try testing.expect(l.problems[2] == .sent_twice);

    // A waiver naming its routine goes stale when the port claims the entry,
    // by a bank-qualified citation or, in bank 2, an AI table row.
    const w = [_]Waiver{.{ .site = 0x024301, .entry = 0x024300, .why = "test" }};
    l = try classify(a, sites, puts, src, &w, &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), l.problems.len);
    l = try classify(a, sites, puts, src, &w, &.{}, try bankCitations(a, "; 02:$4300 `enAI_test`"));
    try testing.expect(l.problems[0] == .stale_waiver);
    const table = src ++ "\n        dw $4300 : dw EnAiTest";
    l = try classify(a, sites, try parsePuts(a, table), table, &w, &.{}, &.{});
    try testing.expect(l.problems[0] == .stale_waiver);

    // A put with no site does not assemble into the ledger.
    try testing.expectError(error.NoSite, parsePuts(a, "        %audio_put(!REQ_SONG)"));
    // The far put, from bank 1, reads as a put (Step 24i).
    const far = try parsePuts(a, "+       %audio_put_long(!REQ_SFX_SQUARE1, $054213)");
    try testing.expectEqual(@as(usize, 1), far.len);
    try testing.expectEqualSlices(u24, &.{0x054213}, far[0].sites);
}

pub const Report = struct { sites: []Site, ledger: Ledger };

/// The ROM's sites, the engine's puts and the ledger over them, or null when
/// no ROM is configured. A ROM or source that cannot be read is an error: it
/// used to be null too, which the CLI printed as "skipped".
pub fn load(gpa: std.mem.Allocator, io: std.Io, rom_path: []const u8) !?Report {
    if (rom_path.len == 0) return null;
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(4 << 20));
    return try fromRom(gpa, io, rom);
}

/// `load`, from ROM bytes already read.
pub fn fromRom(gpa: std.mem.Allocator, io: std.Io, rom: []const u8) !Report {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "engine/main.asm", gpa, .limited(16 << 20));
    const sites = try scan(gpa, rom);
    const puts = try parsePuts(gpa, src);
    var owners: [site_banks.len][]const ?[]const u8 = undefined;
    const cl = try claims(gpa, src);
    for (site_banks, &owners) |bank, *o| o.* = try portedBodies(gpa, rom, bank, cl);
    return .{ .sites = sites, .ledger = try classify(gpa, sites, puts, src, &waivers, &owners, cl) };
}

test "the retail ROM's sites agree with M2RoS bank by bank" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const got = try fromRom(a, testing.io, rom);
    // M2RoS `SRC/bank_00N.asm`: its `ld [sfxRequest_*]`, `[songRequest]`,
    // `[songInterruptionRequest]`, `[audioPauseControl]` and
    // `[songInterruptionPlaying]` stores, and bank 0's four
    // `call silenceAudio_longJump`.
    const expected = [_]usize{ 72 + 4, 22, 87, 8, 10 };
    for (site_banks, expected) |bank, want| {
        var n: usize = 0;
        for (got.sites) |s| n += @intFromBool(s.bank == bank);
        try testing.expectEqual(want, n);
    }
}

test "every site in ported code is sent or waived, and every put names a real site" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    const got = try fromRom(a, testing.io, rom);
    for (got.ledger.problems) |p| std.debug.print("audio_sites: {any}\n", .{p});
    for (got.ledger.rows) |r| {
        if (r.status == .missing) std.debug.print("audio_sites: missing {X:0>2}:{X:0>4} ({s})\n", .{ r.site.bank, r.site.addr, audio_req.slots[r.site.slot].name });
    }
    try testing.expectEqual(@as(usize, 0), got.ledger.problems.len);
    try testing.expectEqual(@as(usize, 0), got.ledger.count(.missing));
}
