//! The table-driven dispatch survey (F4).
//!
//! F4 asks for "a survey pass [that] identifies every other place the original
//! is table-driven, so the maximum possible share of the ~20,000 logic lines
//! reduces to *port the dispatcher, transfer the table*". This is that pass,
//! and it is built out of two things that already exist rather than out of a
//! reading of a disassembly:
//!
//!   1. **`ledger.Observation.edges`** — every `(site, target)` pair the
//!      emulator was observed to take through an indirect jump. The sites are a
//!      fact about a run, not a claim about our reading, which is the honest
//!      form of "survey the ROM": a static tool cannot follow `JP HL` at all,
//!      which is why a vector-seeded static trace reaches 22% of bank 0.
//!   2. **The ROM itself** — a table is then *located* by searching for the
//!      observed targets as a strided run of little-endian in-bank pointers.
//!      No disassembly is required to find one and no address is written down
//!      here: if the run reached two arms of a dispatch, the bytes that name
//!      those two arms at a constant stride are the table, and the search says
//!      where they are.
//!
//! ## Two idioms, and why the site is not always the `JP HL`
//!
//! **Inline tables.** `RST $28` is a thunk at $0028: `POP HL` takes its own
//! return address, which points at the bytes the caller inlined immediately
//! after the `RST`, indexes them, and `JP HL`. Every inline dispatch in the
//! game therefore funnels through **one** `JP HL`, and grouping by it would
//! report a single site with every arm in the game hanging off it.
//! `ledger.Edge` attributes those to the `RST $28` that called the thunk, which
//! is also where the table is — so the table's address for this kind is known
//! by construction, `site + 1`, and the search is a cross-check rather than the
//! only evidence.
//!
//! **Explicit tables.** `LD HL,table` / index / `JP HL` in the caller's own
//! body. Here the `JP HL` *is* the site and the table is somewhere else in the
//! bank, which is what the search is for.
//!
//! ## Execution coverage bootstrapping a static search
//!
//! Three of bank 4's sites share an indexer: each loads a table base into HL,
//! `CALL $46DE` turns an index into an entry, and `JP HL` takes it. **Nothing
//! knew that helper existed until a run reached one of them** — which is the
//! whole reason a static tool stalls on this game. Once it has, the seven bytes
//! `21 lo hi / CD DE 46 / E9` name every other site in the ROM that uses the
//! same helper, and `siblingSites` finds five the observation never entered,
//! each with its table address.
//!
//! Neither half could have done that alone: the run supplies the shape, the
//! bytes supply the rest.
//!
//! ## What the survey does not claim
//!
//! **An unreached site is a hole, and the survey's credibility is in listing
//! them rather than in the count.** A dispatch that only fires for an enemy, a
//! boss, or a menu is invisible to ninety seconds of directed play plus a door
//! sweep, however long either runs. `unreached` names the layers known to exist
//! from Steps 4 and 14 whose dispatches this method cannot have seen, with the
//! reason each is absent, and the report prints them beside the sites it did
//! find rather than under them.
//!
//! **The index derivation is evidence, not inference.** `preamble` disassembles
//! the instructions leading into a site and the report prints them verbatim.
//! Saying what the index *means* is our own reading and belongs in a note, not
//! in a field this file computes.

const std = @import("std");
const ledger = @import("ledger.zig");
const disasm = @import("gb/disasm.zig");

pub const Error = error{OutOfMemory};

pub const bank_size: usize = ledger.bank_size;

/// Entries scanned past a table's base when bounding its arity.
///
/// The pose machine's is the largest inline table in the game at 27 entries
/// (`ledger.pose_count`'s comment), and an enemy AI table could be longer; 128
/// is well past both and costs nothing.
pub const max_entries: usize = 128;

/// Floors for the gate, measured on `zig build verify`'s own observation
/// (2026-09-01) and meant to go up as the survey reaches further.
///
/// Sites rather than arms, because a site is what the survey claims to have
/// found: losing one means the `JP HL` attribution broke, which is the failure
/// the whole method rests on not having.
pub const gate_sites_floor: usize = 5;
pub const gate_located_floor: usize = 3;

/// The share of ledger instructions reachable from a located table's entries.
///
/// A floor on the *answer to F4*, not on the code: it fails if the survey stops
/// being able to account for the layer it says it accounts for.
pub const gate_entry_share_floor: f64 = 30.0;

/// Pointer stride. Every dispatch table this game has been observed to use is a
/// run of 16-bit little-endian in-bank addresses.
///
/// Written as a constant with the search built around it rather than as a
/// parameter, because a stride the search *chose* would be a degree of freedom
/// that lets a coincidence fit: with two observed arms and a free stride,
/// almost any pair of bytes in the bank can be made to explain them.
pub const stride: usize = 2;

pub const Kind = enum {
    /// The table is inlined after a `RST $28`, at `site + 1`.
    inline_rst28,
    /// The table is elsewhere in the bank and was located by search.
    located,
    /// The table is named by a `LD HL,nn` in the bytes leading into the site,
    /// and that address explains every arm the run reached.
    ///
    /// The search needs two arms to tell a table from a coincidence, and three
    /// of this game's dispatches share one indexer (`CALL $46DE` in bank 4) that
    /// the caller hands a base in HL. A site the run entered once therefore has
    /// its base sitting in plain sight three instructions earlier while the
    /// search declines to guess. Reading it is not a weaker answer than the
    /// search -- it is the same answer the search *confirms* wherever both
    /// apply, which a test asserts.
    from_ld_hl,
    /// Two or more arms were observed and no strided pointer run in the bank
    /// explains them. Reported rather than guessed at.
    unlocated,
    /// One arm was observed, which no search can distinguish from a coincidence.
    one_arm,
};

/// One dispatch site: where the indirect jump is, what table feeds it, and
/// which arms the run reached.
pub const Site = struct {
    /// ROM offset of the `RST $28` (inline) or the `JP HL` (explicit).
    site: u32,
    kind: Kind,
    /// ROM offset of the table's first entry, when one was established.
    table: ?u32 = null,
    /// Entries from the table's base to the first arm it names. A table cannot
    /// run past the code it points at when that code follows it, so this is a
    /// real bound -- but a weak one, because it is built only from the arms the
    /// run happened to reach. Null when no arm lies after the table.
    arity_to_first_arm: ?usize = null,
    /// Entries from the base to the next routine the ledger found. The tightest
    /// of the three bounds and the one to quote: routine boundaries come from
    /// the same execution trace as the sites, so this says "the table ends
    /// where the next thing the game runs begins".
    ///
    /// It is what `ledger.zig` already states by hand for the pose machine --
    /// "27 entries before it runs into the next routine" -- computed rather
    /// than remembered.
    arity_to_next_routine: ?usize = null,
    /// Entries that decode as plausible in-bank addresses, scanning from the
    /// base until one does not. A second, independent bound: it can come out
    /// *under* `arity_to_first_arm` when the table holds a deliberate null or a
    /// pointer into another bank, and over it when the code following the table
    /// happens to open with bytes that read as an address. Both are printed,
    /// because a table whose two bounds disagree is one to look at by hand.
    arity_plausible: usize = 0,
    /// The distinct arms the run reached, as ROM offsets, in table-index order
    /// when a table was found and in first-seen order when it was not.
    arms: []u32,
    /// The highest table index any observed arm sat at, when a table was found.
    /// `arms.len` against this is how much of the table the run exercised.
    highest_index: ?usize = null,
    /// Every entry the table holds, read out of the ROM for `arity()` slots --
    /// the arms the run reached *and* the ones it did not.
    ///
    /// This is what turns the survey from "what did we see" into "what is
    /// there", and it is the only honest way to answer F4's *maximum possible*
    /// share: the run reached seven of the pose machine's thirty-one arms, so
    /// counting only what it dispatched to understates the ceiling by a factor
    /// of four. An entry is an address in the ROM; nothing about it depends on
    /// the run having taken it.
    entries: []u16 = &.{},

    pub fn bank(self: Site) u8 {
        return @intCast(self.site / bank_size);
    }

    pub fn addr(self: Site) u16 {
        return offsetToAddr(self.site);
    }

    /// The tightest bound available on the table's length.
    pub fn arity(self: Site) ?usize {
        var best: ?usize = self.arity_to_next_routine;
        if (self.arity_to_first_arm) |n| best = if (best) |b| @min(b, n) else n;
        if (self.arity_plausible != 0) best = if (best) |b| @min(b, self.arity_plausible) else self.arity_plausible;
        return best;
    }

    /// How much of the table the run actually exercised, as a fraction of the
    /// tightest arity bound. Null when there is no bound to be a fraction of.
    pub fn coverage(self: Site) ?f64 {
        const n = self.arity() orelse return null;
        if (n == 0) return null;
        return 100.0 * @as(f64, @floatFromInt(self.arms.len)) / @as(f64, @floatFromInt(n));
    }
};

/// A dispatch site the run never entered, found in the bytes by the shape a
/// site the run *did* enter taught us.
///
/// **This is the one part of the survey that is not seeded by execution, and it
/// is seeded by execution anyway.** Three of bank 4's sites share an indexer:
/// each loads a table base into HL and `CALL $46DE` turns an index into an
/// entry, then `JP HL`. Nothing about `$46DE` was known before the run reached
/// one of those sites; once it has, the seven bytes `21 lo hi / CD DE 46 / E9`
/// name every other site in the ROM that uses the same helper -- including the
/// ones no input schedule has ever provoked.
///
/// A static tool could not have started here: it would have had to know which
/// helper to look for, and that is exactly what a `JP HL` hides.
pub const Sibling = struct {
    /// ROM offset of the `JP HL`.
    site: u32,
    /// ROM offset of the table the `LD HL,nn` names.
    table: u32,
    /// The indexer this site shares with an observed one.
    indexer: u16,
    /// True when the run did reach this site, so the report can say which of
    /// the family are new.
    observed: bool,
};

/// A dispatch layer this method cannot have reached, and why.
///
/// Written down rather than computed: the reason a site is absent is a fact
/// about what the observation schedule does, and no amount of looking at the
/// bytes recovers it. Each names the mechanical evidence that the layer exists,
/// so "we know it is there and we did not see it" is a checkable statement.
pub const Unreached = struct {
    name: []const u8,
    /// What proves the layer exists, in this repository's own terms.
    evidence: []const u8,
    /// Why the observation could not have dispatched through it.
    why: []const u8,
};

pub const unreached = [_]Unreached{
    .{
        .name = "enemy AI dispatch",
        .evidence = "`offsets.enemy_header_pointers` and `enemy_headers`; `entity.Header` is an " ++
            "11-byte record and the four enemy tables share one 255-entry id space, all " ++
            "round-tripped byte-for-byte by the gate's `map/door/sprite` rung",
        .why = "No enemy is ever spawned. The observation boots, explores with a fixed input " ++
            "schedule, and calls the door interpreter directly on a freshly booted machine; " ++
            "none of those puts a live enemy in a slot, so its per-frame AI pointer is never " ++
            "taken. F4 names this layer separately for exactly this reason. " ++
            "**Entered on the cart on 2026-09-09 by B4b, and still unreached here, which is " ++
            "the distinction this table is about.** The port now dispatches it -- as a table " ++
            "from the Game Boy address in the slot to a ported routine, because the original's " ++
            "`jp hl` goes through a bank-2 address that means nothing on a 65816 -- and the " ++
            "oracle segment grades two of its arms, `enAI_smallBug` and `enAI_senjooShirk`, " ++
            "across the seven hundred frames it now runs. What has not changed is what this " ++
            "row claims: *this repository's own observation of the Game Boy* still never " ++
            "reaches the layer, so the sites behind it are still ones no static scan here has " ++
            "seen. The cart having a dispatch is not the same fact as the survey having " ++
            "watched one",
    },
    .{
        .name = "door script opcode dispatch",
        .evidence = "512 door pointers and 1872 door ops round-tripping through `door.zig`, " ++
            "reported by the gate",
        .why = "Reached, but not through `JP HL`: the interpreter switches on an opcode byte " ++
            "rather than jumping through a pointer table, so it produces no dispatch edge. It " ++
            "is table-driven in the sense F4 cares about and is already a first-class " ++
            "requirement, so it is accounted for there rather than counted here",
    },
    .{
        .name = "menu, map and pause dispatch",
        .evidence = "`oracle.unsupportedBits` names Start and Select as bits the port has no " ++
            "key for; the any% run taps Select twice and opens nothing",
        .why = "The observation's input schedule never opens a menu, and `duration.zig` " ++
            "measured that neither published run does either inside its horizon. Whatever " ++
            "dispatch the item and map screens use is invisible to every run this repository " ++
            "has taken",
    },
    .{
        .name = "boss and cutscene sequencing",
        .evidence = "`save.fields`' Metroid counter drives `IF_MET_LESS`, which trips at or " ++
            "below its operand, so the first `$46` gate opens on one kill; the Queen opcodes " ++
            "are named in F4's opcode set",
        .why = "No Alpha Metroid, no Queen, and no ending. The any% run reaches four of seven " ++
            "map banks before its replay leaves the published route, and none of the " ++
            "observation's schedules fight anything",
    },
};

// ---- Locating a table -------------------------------------------------------

fn offsetToAddr(off: u32) u16 {
    const in_bank: u16 = @intCast(off % bank_size);
    return if (off < bank_size) in_bank else in_bank + 0x4000;
}

fn addrOk(bank: u8, a: u16) bool {
    return if (bank == 0) a < 0x4000 else a >= 0x4000 and a < 0x8000;
}

fn read16(rom: []const u8, off: usize) ?u16 {
    if (off + 1 >= rom.len) return null;
    return @as(u16, rom[off]) | (@as(u16, rom[off + 1]) << 8);
}

/// Does the run of pointers at `base` name every one of `want`?
///
/// Returns the highest index used, or null if any target is missing inside
/// `max_entries`.
///
/// **Deliberately permissive about what sits between the hits**, and a test
/// pins the consequence. Requiring every entry consulted to be a plausible
/// in-bank address sounds stricter and is worse: a real table may hold a null
/// or an out-of-bank slot, and stopping at the first one truncates the scan
/// before it reaches an arm that is really there. What discriminates is not
/// this function but `locate`'s ranking -- a base 66 slots wide that explains
/// the arms loses to one that explains them in 2 -- so the loose predicate here
/// is paired with a tight ordering there.
fn explains(rom: []const u8, base: usize, want: []const u32) ?usize {
    var highest: usize = 0;
    for (want) |t| {
        const a = offsetToAddr(t);
        var k: usize = 0;
        const found = while (k < max_entries) : (k += 1) {
            const e = read16(rom, base + k * stride) orelse break false;
            if (e == a) break true;
        } else false;
        if (!found) return null;
        highest = @max(highest, k);
    }
    return highest;
}

/// Find the table feeding a site, by searching its bank for a strided pointer
/// run that names every arm the run reached.
///
/// Candidates are ranked by the tightest index span, so a base that explains
/// the arms in five consecutive slots beats one that explains them in ninety.
/// Ties go to the lower address, which makes the answer deterministic.
const Located = struct { base: u32, highest: usize };

/// How far back to look for the `LD HL,nn` that sets a table base up.
///
/// Short on purpose. A wide window turns "the instruction that loads this
/// table" into "some instruction somewhere that mentions an address explaining
/// the arms", which is a search with extra steps.
pub const load_window: u32 = 16;

/// The table a `LD HL,nn` just before the site names, when it explains every
/// observed arm. See `Kind.from_ld_hl`.
fn fromLoadHl(rom: []const u8, site: u32, arms: []const u32) ?Located {
    const bank: u8 = @intCast(site / bank_size);
    const bank_start: u32 = @as(u32, bank) * @as(u32, bank_size);
    var off: u32 = if (site > bank_start + load_window) site - load_window else bank_start;
    while (off + 2 < site and off + 2 < rom.len) : (off += 1) {
        if (rom[off] != 0x21) continue; // LD HL,nn
        const nn = @as(u16, rom[off + 1]) | (@as(u16, rom[off + 2]) << 8);
        if (!addrOk(bank, nn)) continue;
        const base: u32 = bank_start + (if (bank == 0) @as(u32, nn) else @as(u32, nn) - 0x4000);
        const highest = explains(rom, base, arms) orelse continue;
        return .{ .base = base, .highest = highest };
    }
    return null;
}

fn locate(rom: []const u8, bank: u8, arms: []const u32) ?Located {
    if (arms.len < 2) return null;
    const start = @as(usize, bank) * bank_size;
    const end = @min(rom.len, start + bank_size);
    var best: ?Located = null;
    var base = start;
    while (base + stride <= end) : (base += 1) {
        const highest = explains(rom, base, arms) orelse continue;
        if (best) |b| {
            if (highest >= b.highest) continue;
        }
        best = .{ .base = @intCast(base), .highest = highest };
    }
    return best;
}

/// How many entries a table has, bounded two ways. See `Site`.
const Arity = struct { to_first_arm: ?usize, to_next_routine: ?usize, plausible: usize };

fn arityOf(rom: []const u8, l: ledger.Ledger, bank: u8, base: u32, arms: []const u32) Arity {
    var plausible: usize = 0;
    while (plausible < max_entries) : (plausible += 1) {
        const e = read16(rom, base + plausible * stride) orelse break;
        if (!addrOk(bank, e)) break;
    }

    // The sharp bound: a table cannot extend into the first arm it names, when
    // that arm follows it. An arm *before* the table says nothing.
    const base_addr = offsetToAddr(base);
    var lowest_after: ?u16 = null;
    for (arms) |t| {
        const a = offsetToAddr(t);
        if (a <= base_addr) continue;
        lowest_after = if (lowest_after) |low| @min(low, a) else a;
    }
    const to_first_arm: ?usize = if (lowest_after) |low| (low - base_addr) / stride else null;

    // And the tightest: where the next routine the ledger found begins.
    var next_routine: ?u16 = null;
    for (l.routines) |r| {
        if (r.bank != bank or r.addr <= base_addr) continue;
        next_routine = if (next_routine) |nr| @min(nr, r.addr) else r.addr;
    }
    const to_next: ?usize = if (next_routine) |nr| (nr - base_addr) / stride else null;

    return .{ .to_first_arm = to_first_arm, .to_next_routine = to_next, .plausible = plausible };
}

// ---- The survey -------------------------------------------------------------

pub const Survey = struct {
    sites: []Site,
    /// Sites found by the shape rather than by the run. See `Sibling`.
    siblings: []Sibling,
    /// Instructions the ledger attributes to routines that are arms of some
    /// dispatch, and the ledger's total, so the share is read as a fraction of
    /// a stated denominator rather than of a remembered one.
    arm_instructions: usize,
    total_instructions: usize,
    /// Arms whose ROM offset falls in no ledger routine at all. A nonzero count
    /// is a discrepancy between the two mechanical inventories, not a rounding
    /// detail, and the report prints it.
    arms_without_row: usize,

    /// Instructions statically reachable from *every* table entry, observed or
    /// not. See `Site.entries` and `reachableInstructions`.
    entry_instructions: usize,

    pub fn deinit(self: *Survey, allocator: std.mem.Allocator) void {
        for (self.sites) |s| {
            allocator.free(s.arms);
            allocator.free(s.entries);
        }
        allocator.free(self.sites);
        allocator.free(self.siblings);
        self.sites = &.{};
        self.siblings = &.{};
    }

    /// Sibling sites the run never entered.
    pub fn unobservedSiblings(self: Survey) usize {
        var n: usize = 0;
        for (self.siblings) |sib| n += @intFromBool(!sib.observed);
        return n;
    }

    /// The ceiling F4's survey criterion asks for: the share of the ledger's
    /// instructions that a dispatcher plus its table could account for, if
    /// every arm of every table a run has seen were counted rather than only
    /// the arms it took.
    pub fn entryShare(self: Survey) f64 {
        if (self.total_instructions == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(self.entry_instructions)) /
            @as(f64, @floatFromInt(self.total_instructions));
    }

    /// The share of the ledger's instructions that sit behind a dispatch — the
    /// number F4's survey criterion is asking for.
    pub fn armShare(self: Survey) f64 {
        if (self.total_instructions == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(self.arm_instructions)) /
            @as(f64, @floatFromInt(self.total_instructions));
    }

    pub fn located(self: Survey) usize {
        var n: usize = 0;
        for (self.sites) |s| n += @intFromBool(s.table != null);
        return n;
    }

    /// Table entries across every site whose table was located, at the tightest
    /// bound. This is the data that transfers instead of being rewritten.
    pub fn tableEntries(self: Survey) usize {
        var n: usize = 0;
        for (self.sites) |s| n += s.arity() orelse 0;
        return n;
    }
};

/// Build the survey from an observation and the ledger built from it.
pub fn survey(
    allocator: std.mem.Allocator,
    rom: []const u8,
    obs: ledger.Observation,
    l: ledger.Ledger,
) Error!Survey {
    // Group the edges by site, preserving first-seen order of both.
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(allocator);
    var groups: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    defer {
        var it = groups.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        groups.deinit(allocator);
    }
    for (obs.edges) |e| {
        const gop = try groups.getOrPut(allocator, e.site);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try order.append(allocator, e.site);
        }
        try gop.value_ptr.append(allocator, e.target);
    }

    var sites = try allocator.alloc(Site, order.items.len);
    errdefer allocator.free(sites);
    var built: usize = 0;
    errdefer for (sites[0..built]) |s| allocator.free(s.arms);

    for (order.items, 0..) |site_off, i| {
        const arms_list = groups.get(site_off).?;
        const bank: u8 = @intCast(site_off / bank_size);
        const arms = try allocator.dupe(u32, arms_list.items);
        built = i + 1;
        std.mem.sort(u32, arms, {}, std.sort.asc(u32));

        var s: Site = .{ .site = site_off, .kind = .one_arm, .arms = arms };

        // An inline table's address is known by construction. The search still
        // runs, as a cross-check: if it finds a different base that also
        // explains the arms, the inline claim is the one to trust, and if it
        // finds the same one that is two derivations agreeing.
        const inline_base: ?u32 = if (site_off + 1 < rom.len and rom[site_off] == 0xEF)
            site_off + 1
        else
            null;

        const searched = locate(rom, bank, arms);
        if (inline_base) |b| {
            if (explains(rom, b, arms)) |h| {
                s.kind = .inline_rst28;
                s.table = b;
                s.highest_index = h;
            }
        }
        if (s.table == null) {
            if (searched) |f| {
                s.kind = .located;
                s.table = f.base;
                s.highest_index = f.highest;
            } else if (fromLoadHl(rom, site_off, arms)) |f| {
                s.kind = .from_ld_hl;
                s.table = f.base;
                s.highest_index = f.highest;
            } else if (arms.len >= 2) {
                s.kind = .unlocated;
            }
        }

        if (s.table) |b| {
            const a = arityOf(rom, l, bank, b, arms);
            s.arity_to_first_arm = a.to_first_arm;
            s.arity_to_next_routine = a.to_next_routine;
            s.arity_plausible = a.plausible;
            if (s.arity()) |n| {
                var es: std.ArrayList(u16) = .empty;
                errdefer es.deinit(allocator);
                for (0..n) |k| {
                    const e = read16(rom, b + k * stride) orelse break;
                    if (!addrOk(bank, e)) continue;
                    try es.append(allocator, e);
                }
                s.entries = try es.toOwnedSlice(allocator);
            }
        }
        sites[i] = s;
    }

    // What sits behind the dispatches, counted out of the ledger so the two
    // mechanical inventories are read against each other rather than
    // separately.
    var counted: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer counted.deinit(allocator);
    var arm_instructions: usize = 0;
    var arms_without_row: usize = 0;
    for (sites) |s| {
        for (s.arms) |t| {
            const r = routineAt(l, t) orelse {
                arms_without_row += 1;
                continue;
            };
            const key = @as(u32, r.bank) * @as(u32, bank_size) + r.addr;
            const gop = try counted.getOrPut(allocator, key);
            if (gop.found_existing) continue;
            arm_instructions += r.instructions;
        }
    }

    var total: usize = 0;
    for (l.routines) |r| total += r.instructions;

    return .{
        .sites = sites,
        .siblings = try siblingSites(allocator, rom, sites),
        .arm_instructions = arm_instructions,
        .entry_instructions = try reachableInstructions(allocator, rom, sites),
        .total_instructions = total,
        .arms_without_row = arms_without_row,
    };
}

/// The helper a site calls to turn an index into a table entry, when the three
/// bytes before the `JP HL` are a `CALL`.
fn indexerOf(rom: []const u8, site: u32) ?u16 {
    if (site < 3) return null;
    if (rom[site - 3] != 0xCD) return null; // CALL nn
    return @as(u16, rom[site - 2]) | (@as(u16, rom[site - 1]) << 8);
}

/// Every `LD HL,nn / CALL <indexer> / JP HL` in the ROM, for each indexer some
/// observed site uses. See `Sibling`.
pub fn siblingSites(
    allocator: std.mem.Allocator,
    rom: []const u8,
    sites: []const Site,
) Error![]Sibling {
    var indexers: std.AutoHashMapUnmanaged(u16, void) = .empty;
    defer indexers.deinit(allocator);
    for (sites) |s| {
        const idx = indexerOf(rom, s.site) orelse continue;
        try indexers.put(allocator, idx, {});
    }

    var out: std.ArrayList(Sibling) = .empty;
    errdefer out.deinit(allocator);
    if (indexers.count() == 0) return out.toOwnedSlice(allocator);

    var off: u32 = 0;
    while (off + 7 <= rom.len) : (off += 1) {
        if (rom[off] != 0x21) continue; // LD HL,nn
        if (rom[off + 3] != 0xCD) continue; // CALL nn
        if (rom[off + 6] != 0xE9) continue; // JP HL
        const target = @as(u16, rom[off + 4]) | (@as(u16, rom[off + 5]) << 8);
        if (!indexers.contains(target)) continue;

        const bank: u8 = @intCast(off / bank_size);
        const nn = @as(u16, rom[off + 1]) | (@as(u16, rom[off + 2]) << 8);
        if (!addrOk(bank, nn)) continue;
        const bank_start: u32 = @as(u32, bank) * @as(u32, bank_size);
        const table: u32 = bank_start + (if (bank == 0) @as(u32, nn) else @as(u32, nn) - 0x4000);

        const jp = off + 6;
        var observed = false;
        for (sites) |s| {
            if (s.site == jp) observed = true;
        }
        try out.append(allocator, .{ .site = jp, .table = table, .indexer = target, .observed = observed });
    }
    return out.toOwnedSlice(allocator);
}

/// Instructions statically reachable from every located table's entries.
///
/// One trace per bank over the union of that bank's entries, so a subroutine
/// two arms share is counted once. `disasm.trace` follows conditionals and
/// falls *through* a `CALL` rather than into it, which bounds how far this
/// bleeds past the arms themselves: what it counts is the arm bodies and
/// whatever they tail-jump to, not the whole call graph beneath them.
///
/// This is a ceiling and is reported as one. A tail-jump into shared code
/// attributes that code to the dispatch, which is the right answer when the
/// dispatcher is what reaches it and an overcount when something else does too.
pub fn reachableInstructions(
    allocator: std.mem.Allocator,
    rom: []const u8,
    sites: []const Site,
) Error!usize {
    var total: usize = 0;
    for (0..ledger.bank_count) |b| {
        const bank: u8 = @intCast(b);
        var entries: std.ArrayList(u16) = .empty;
        defer entries.deinit(allocator);
        for (sites) |s| {
            if (s.bank() != bank) continue;
            for (s.entries) |e| try entries.append(allocator, e);
        }
        if (entries.items.len == 0) continue;

        const start = b * bank_size;
        if (start >= rom.len) continue;
        const code = rom[start..@min(rom.len, start + bank_size)];
        const base: u16 = if (bank == 0) 0 else 0x4000;
        var listing = disasm.trace(allocator, code, base, entries.items) catch continue;
        defer listing.deinit(allocator);
        for (listing.starts) |hit| total += @intFromBool(hit);
    }
    return total;
}

/// The ledger routine whose body contains a ROM offset, or null.
pub fn routineAt(l: ledger.Ledger, off: u32) ?ledger.Routine {
    const bank: u8 = @intCast(off / bank_size);
    const a = offsetToAddr(off);
    var best: ?ledger.Routine = null;
    for (l.routines) |r| {
        if (r.bank != bank) continue;
        if (a < r.addr or a >= r.end) continue;
        // The tightest containing body, so a routine nested inside another's
        // span is preferred to the one that swallowed it.
        if (best) |b| {
            if (r.span >= b.span) continue;
        }
        best = r;
    }
    return best;
}

/// The instructions leading into a site, disassembled.
///
/// Evidence for how the index is derived, printed verbatim by the report. It is
/// a backwards decode over a fixed window, which is not sound in general -- x86
/// it is not, but SM83 instructions are one to three bytes and the window is
/// short, so a wrong alignment resynchronises within a couple of instructions
/// and the last few lines before the site are right. The report says so rather
/// than presenting these as a disassembly.
pub fn preamble(
    rom: []const u8,
    site: u32,
    window: usize,
    out: *std.ArrayList(disasm.Insn),
    allocator: std.mem.Allocator,
) Error!void {
    const bank: u8 = @intCast(site / bank_size);
    const bank_start = @as(usize, bank) * bank_size;
    const from = if (site > bank_start + window) site - window else bank_start;
    var off = from;
    while (off < site) {
        const win = rom[off..@min(rom.len, off + 4)];
        const insn = disasm.decode(win, offsetToAddr(@intCast(off)));
        try out.append(allocator, insn);
        off += @max(1, insn.len);
    }
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "a table is located from its arms, and a base that explains only one is not" {
    var rom = [_]u8{0} ** bank_size;
    // A four-entry table at $0100 naming $0200, $0210, $0220, $0230.
    const targets = [_]u16{ 0x0200, 0x0210, 0x0220, 0x0230 };
    for (targets, 0..) |t, i| {
        rom[0x0100 + i * 2] = @truncate(t);
        rom[0x0100 + i * 2 + 1] = @truncate(t >> 8);
    }
    // And a decoy 64 slots earlier that names only the first.
    rom[0x0080] = 0x00;
    rom[0x0081] = 0x02;

    const arms = [_]u32{ 0x0200, 0x0220 };
    const found = locate(&rom, 0, &arms) orelse return error.NotLocated;
    try testing.expectEqual(@as(u32, 0x0100), found.base);
    try testing.expectEqual(@as(usize, 2), found.highest);

    // **The decoy is not rejected, and that is the point of the ranking.**
    // Scanning `max_entries` slots from $0080 walks into the real table and
    // finds both arms -- at index 64 and index 66. This assertion was written
    // the other way round first, expecting null, on the assumption that a decoy
    // holding one arm could not reach the other; it can, and the test was wrong
    // rather than the code. What keeps the answer right is that `locate` prefers
    // the tightest index span, so a base that explains the arms in 2 slots beats
    // one that needs 66.
    try testing.expectEqual(@as(?usize, 66), explains(&rom, 0x0080, &arms));

    // One arm is refused outright rather than matched to the first place its
    // bytes appear, which would be a coincidence dressed as a finding.
    const one = [_]u32{0x0200};
    try testing.expectEqual(@as(?Located, null), locate(&rom, 0, &one));
}

// The rest of what this file claims is checked in `zig build verify`'s dispatch
// rung rather than here, and deliberately: `ledger.zig` states the rule --
// "two minutes of emulation and a 512-door sweep belong in the gate, not the
// unit suite" -- and every claim about the *retail ROM's* sites needs an
// observation to make. The first version of these tests ran a 24-second
// observation under `testing.allocator`, in every module that transitively
// imports this one, and turned a five-minute suite into one that did not
// finish. `checkAgainstObservation` is where those assertions live now; the
// gate already has the observation in hand, so they cost nothing there.

/// What the gate asserts about a survey of the retail ROM.
///
/// Returned as a list of complaints rather than as `!void`, so the rung prints
/// everything that is wrong in one pass instead of stopping at the first --
/// `verify.zig`'s shape everywhere else, and the useful one when a change moves
/// several routines at once.
pub const Complaint = struct { what: []const u8, detail: []const u8 };

pub fn checkAgainstObservation(
    allocator: std.mem.Allocator,
    rom: []const u8,
    sv: Survey,
    out: *std.ArrayList(Complaint),
) Error!void {
    // ---- The two dispatches `engine/main.asm` already cites ----------------
    //
    // `ledger.known` carries both by Game Boy address. The survey has to agree
    // with the citations, or one of the two is describing a routine that moved.
    if (findSite(sv, 0x0D4A)) |pose| {
        if (pose.kind != .inline_rst28 or pose.table != @as(u32, 0x0D4B)) {
            try out.append(allocator, .{
                .what = "the pose machine's table",
                .detail = "0:$0D4A no longer reads as a RST $28 with its table inline at 0:$0D4B",
            });
        }
        // `ledger.zig` states 27 by hand: "27 entries before it runs into the
        // next routine". The computed bound comes from routine boundaries a run
        // found, so it is not obliged to be identical -- but 3 or 300 would mean
        // the bound is not measuring what it says it measures.
        const n = pose.arity() orelse 0;
        if (n < 20 or n > 40) {
            try out.append(allocator, .{
                .what = "the pose machine's arity",
                .detail = "the computed bound is nowhere near the 27 entries ledger.zig states by hand",
            });
        }
        for (pose.entries) |e| {
            if (addrOk(0, e)) continue;
            try out.append(allocator, .{
                .what = "a pose table entry",
                .detail = "an entry read out of the table is not an in-bank address",
            });
            break;
        }
    } else {
        try out.append(allocator, .{
            .what = "the pose machine's dispatch",
            .detail = "0:$0D4A is not among the sites; the run never reached HandlePose",
        });
    }

    if (findSite(sv, @as(u32, 1 * bank_size + 0x0C1C))) |sprite| {
        if (sprite.kind != .inline_rst28 or sprite.table != @as(u32, 1 * bank_size + 0x0C1D)) {
            try out.append(allocator, .{
                .what = "the sprite dispatch's table",
                .detail = "1:$4C1C no longer reads as a RST $28 with its table inline at 1:$4C1D",
            });
        }
    } else {
        try out.append(allocator, .{
            .what = "the sprite dispatch",
            .detail = "1:$4C1C is not among the sites; the run never reached SamusSpriteId",
        });
    }

    // ---- The thunk's own `JP HL` is never a site ---------------------------
    //
    // It was, for the first run of this file, and it reported one site with
    // nineteen arms: every inline dispatch in the game merged into the one
    // address they all pass through.
    if (ledger.rst28Jump(rom)) |thunk| {
        for (sv.sites) |s| {
            if (s.site != thunk) continue;
            try out.append(allocator, .{
                .what = "the RST $28 thunk",
                .detail = "the thunk's own JP HL is being reported as a site, so inline dispatches are merged",
            });
        }
    } else {
        try out.append(allocator, .{
            .what = "the RST $28 thunk",
            .detail = "no JP HL found within reach of $0028; the inline attribution cannot work",
        });
    }

    // ---- A located table is the address the code itself loads --------------
    //
    // The strongest check available on the search, and it needs no listing: the
    // search reaches its answer from the observed arms without ever reading the
    // `LD HL,nn` that sets the table up. Two independent derivations agreeing.
    var confirmed: usize = 0;
    for (sv.sites) |s| {
        if (s.kind != .located) continue;
        const table_addr = offsetToAddr(s.table.?);
        var off = s.site -| 16;
        while (off + 2 < s.site) : (off += 1) {
            if (rom[off] != 0x21) continue; // LD HL,nn
            const nn = @as(u16, rom[off + 1]) | (@as(u16, rom[off + 2]) << 8);
            if (nn == table_addr) confirmed += 1;
        }
    }
    // Not every explicit dispatch loads its table within sixteen bytes of the
    // jump, so this wants at least one that does -- rather than demanding a
    // shape the game need not have.
    if (confirmed == 0) {
        try out.append(allocator, .{
            .what = "the table search",
            .detail = "no searched table matches the LD HL,nn that sets it up; the two derivations disagree",
        });
    }

    // ---- Sites the bytes name once a run has taught us the shape ----------
    for (sv.sites) |s| {
        if (s.site < 3 or rom[s.site - 3] != 0xCD) continue;
        var present = false;
        for (sv.siblings) |sib| {
            if (sib.site == s.site) present = true;
        }
        if (present) continue;
        try out.append(allocator, .{
            .what = "the sibling scan",
            .detail = "a site the run reached through a shared indexer is missing from the family the pattern finds",
        });
    }
}

fn findSite(sv: Survey, site: u32) ?Site {
    for (sv.sites) |s| {
        if (s.site == site) return s;
    }
    return null;
}

test "the RST $28 thunk's JP HL is found in the ROM, not written down" {
    const allocator = testing.allocator;
    const rom = try testrom.load(allocator) orelse return error.SkipZigTest;
    defer allocator.free(rom);

    // Measured: `ADD A,A / POP HL / LD E,A / LD D,$00 / ADD HL,DE / LD E,(HL) /
    // INC HL / LD D,(HL) / PUSH DE / POP HL / JP HL`, so the jump is at $0033.
    // Asserted here so that a ROM whose thunk is a different shape fails loudly
    // rather than silently attributing every inline dispatch in the game to the
    // thunk -- which is what an eight-byte guess did. No emulation: this reads
    // eleven bytes.
    try testing.expectEqual(@as(?u32, 0x0033), ledger.rst28Jump(rom));
}

test "the sibling scan finds a family from a shape, in the bytes alone" {
    // Also no emulation. The indexer is supplied here rather than discovered,
    // which is the half a run is needed for; what this checks is that given one,
    // the pattern finds the family -- and that it finds more than the sites any
    // run has entered, which is the whole reason the scan exists.
    const allocator = testing.allocator;
    const rom = try testrom.load(allocator) orelse return error.SkipZigTest;
    defer allocator.free(rom);

    // A single fake site whose three preceding bytes are `CALL $46DE`, so
    // `indexerOf` reads the helper bank 4's dispatches share.
    // 4:$448E, whose three preceding bytes are `CD DE 46`. As a ROM offset that
    // is `4 * bank_size + ($448E - $4000)`; the first version of this line
    // dropped the $4000 subtraction's arithmetic and pointed four bytes past it.
    const seed = [_]Site{.{ .site = 4 * bank_size + (0x448E - 0x4000), .kind = .located, .arms = &.{} }};
    try testing.expectEqual(@as(?u16, 0x46DE), indexerOf(rom, seed[0].site));

    const fam = try siblingSites(allocator, rom, &seed);
    defer allocator.free(fam);
    try testing.expect(fam.len >= 6);
    var unobserved: usize = 0;
    for (fam) |sib| unobserved += @intFromBool(!sib.observed);
    try testing.expect(unobserved >= 5);
    // Every one names a table inside its own bank.
    for (fam) |sib| try testing.expectEqual(@as(u8, 4), @as(u8, @intCast(sib.table / bank_size)));
}
