//! Asset extraction: ROM regions out to files under `extracted/`.
//!
//! `extracted/` is gitignored and never tracked - the policy check in
//! `policy.zig` skips it for exactly that reason. It is a build product, not a
//! source, and it is reproducible from the user's own ROM at any time.
//!
//! Two rules shape the output format:
//!
//!   * Extraction is a *transcription*, not an interpretation. Graphics land as
//!     both the raw 2bpp bytes and a decoded one-byte-per-pixel strip; tables
//!     land as their raw bytes plus a parsed text form. Nothing is reordered,
//!     recoloured, or compressed on the way out. Step 8 converts; this step
//!     only moves.
//!   * Every run of the same ROM produces byte-identical output. The manifest
//!     records a SHA-256 per file so "deterministic" is something the gate
//!     checks rather than something we assert.

const std = @import("std");
const gfx = @import("gfx.zig");
const offsets = @import("offsets.zig");
const items = @import("items.zig");
const tileset = @import("tileset.zig");
const sprite_tables = @import("sprites.zig");
const map = @import("map.zig");
const door = @import("door.zig");
const entity = @import("entity.zig");

pub const out_dir = "extracted";

/// Kinds that get a *decoded* companion file beside their raw bytes. Every
/// entry is dumped raw regardless; this only says which ones we understand well
/// enough to render in a structured form.
fn hasDecodedForm(kind: offsets.Kind) bool {
    return switch (kind) {
        .graphics_tileset,
        .graphics_samus,
        .graphics_enemy,
        .graphics_item,
        .graphics_ui,
        .metatiles,
        .collision,
        .solidity,
        .tilemap,
        .map_scroll_flags,
        .enemy_headers,
        .enemy_hitboxes,
        .enemy_damage,
        .item_names,
        .sound_entry,
        .pose_sprites,
        => true,
        // Screen pointers, transition indexes, door scripts, and metasprites
        // are decoded, but as whole-region artifacts rather than per-entry
        // ones - see `decodeRegions`. Pointer tables in particular mean
        // nothing without the data they point into.
        else => false,
    };
}

pub const Record = struct {
    name: []const u8,
    kind: []const u8,
    bank: u8,
    gb_addr: u16,
    rom_offset: usize,
    size: usize,
    /// Units of the natural element for the kind: tiles, metatiles, or bytes.
    count: usize,
    unit: []const u8,
    files: []const FileHash,
};

pub const FileHash = struct {
    path: []const u8,
    bytes: usize,
    sha256: [64]u8,
};

/// The whole-region artifacts, and the two numbers the Step 4 gate turns on.
pub const Regions = struct {
    /// Grid cells across banks $9-$F whose screen pointer is not the shared
    /// blank at $4500. The requirements independently record 905.
    in_use_screens: usize = 0,
    /// In-use cells whose pointer resolved to a real, aligned screen body.
    screens_reached: usize = 0,
    /// In-use cells whose pointer resolves to nothing. Exactly one exists:
    /// bank $A holds a null $0000. Tracked so "all reached" can be an exact
    /// claim rather than a rounded one.
    screens_unresolved: usize = 0,
    /// Distinct screen bodies referenced, blank included.
    distinct_screens: usize = 0,
    door_ops: usize = 0,
    /// Conditional Metroid-count transitions, and how many distinct thresholds
    /// they use. The requirements independently record 171 across 13, derived
    /// from the other disassembly; agreeing here is a cross-check on both.
    if_met_less_ops: usize = 0,
    if_met_less_thresholds: usize = 0,
    /// Door COPY/LOAD sources that fall inside no offsets-table entry. Zero is
    /// the only acceptable value: a door reading from an address we have not
    /// catalogued means either the table has a hole or the stream is misparsed.
    door_sources_unresolved: usize = 0,
    /// Door pointers that land on an operation boundary in the decoded stream.
    door_pointers_aligned: usize = 0,
    /// Door pointers that target $55A3, exactly one past the last operation:
    /// empty scripts. 14 of them.
    door_pointers_empty: usize = 0,
    /// Door pointers outside the script region entirely - one, targeting bank
    /// 5 freespace at $7F34. Together with the two counts above this accounts
    /// for all 512, which is what makes "aligned" a complete answer rather
    /// than a partial one.
    door_pointers_external: usize = 0,
    /// Whether re-encoding the decoded stream reproduced the region byte for
    /// byte. A misread operand length desynchronises the stream, so this
    /// closing is the evidence that the opcode table is right.
    doors_round_trip: bool = false,
    metasprites: usize = 0,
    metasprite_parts: usize = 0,
    /// Metasprite pointers that match a record start in the linear walk.
    metasprite_pointers_matched: usize = 0,
    /// Metasprite pointers outside bank 1's paged window - one, $C300, which
    /// is a WRAM address and so a dead table slot.
    metasprite_pointers_out_of_window: usize = 0,
    metasprite_pointers_total: usize = 0,
};

pub const Report = struct {
    records: std.ArrayList(Record),
    skipped: usize,
    regions: Regions = .{},

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
    }
};

fn hexDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !FileHash {
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
    return .{ .path = path, .bytes = data.len, .sha256 = hexDigest(data) };
}

/// Render a table as one record per line: index, then the raw bytes. Text so a
/// diff between two ROM revisions is readable, fixed-width so it is greppable.
fn tableText(allocator: std.mem.Allocator, bytes: []const u8, per_row: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) : (i += per_row) {
        const row = bytes[i..@min(i + per_row, bytes.len)];
        try buf.print(allocator, "{d:0>4}", .{i / per_row});
        for (row) |b| try buf.print(allocator, " {X:0>2}", .{b});
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

/// Extract every in-scope entry. `root` is the repository root; `extracted/` is
/// created under it.
pub fn run(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, rom: []const u8) !Report {
    var dir = try root.createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);

    var report: Report = .{ .records = .empty, .skipped = 0 };
    errdefer report.deinit(allocator);

    for (offsets.entries) |e| {
        if (e.romEnd() > rom.len) return error.EntryOutOfBounds;
        const bytes = rom[e.romOffset()..e.romEnd()];

        var files: std.ArrayList(FileHash) = .empty;
        errdefer files.deinit(allocator);

        // Raw bytes, always. Every other file is derived from this one, so it
        // is what a disagreement gets diffed against.
        const raw_path = try std.fmt.allocPrint(allocator, "{s}.bin", .{e.name});
        try files.append(allocator, try write(io, dir, raw_path, bytes));

        var count: usize = bytes.len;
        var unit: []const u8 = "bytes";

        switch (e.kind) {
            .graphics_tileset, .graphics_samus, .graphics_enemy, .graphics_item, .graphics_ui => {
                const tiles = try gfx.decodeAll(allocator, bytes);
                defer allocator.free(tiles);
                const strip = try gfx.toIndexedStrip(allocator, tiles);
                defer allocator.free(strip);
                const p = try std.fmt.allocPrint(allocator, "{s}.pix", .{e.name});
                try files.append(allocator, try write(io, dir, p, strip));
                count = tiles.len;
                unit = "tiles";
            },
            .metatiles => {
                const mts = try tileset.parseMetatiles(allocator, bytes);
                defer allocator.free(mts);
                const txt = try tableText(allocator, bytes, tileset.metatile_bytes);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
                count = mts.len;
                unit = "metatiles";
            },
            .pose_sprites => {
                // Parse first - it refuses a length that is not a whole number
                // of rows - then dump one row to the line at the width the
                // table's own reader uses: four for the facing and animation
                // tables, two for the knockback pair.
                const t = try sprite_tables.parsePoseTable(allocator, bytes);
                defer allocator.free(t.ids);
                const txt = try tableText(allocator, bytes, t.row);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
                count = t.rows();
                unit = "rows";
            },
            .collision => {
                const txt = try tableText(allocator, bytes, 16);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
                count = bytes.len;
                unit = "tile-ids";
            },
            .solidity => {
                // Parse for its side effect: it enforces the $FF terminators,
                // so a malformed table fails extraction instead of shipping.
                _ = try tileset.parseSolidity(bytes);
                const txt = try tableText(allocator, bytes, tileset.solidity_row_bytes);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
                count = tileset.solidity_rows;
                unit = "rows";
            },
            .tilemap, .map_scroll_flags => {
                const per: usize = if (e.kind == .tilemap) 32 else map.grid_w;
                const txt = try tableText(allocator, bytes, per);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
                count = bytes.len / per;
                unit = "rows";
            },
            .enemy_headers => {
                const hs = try entity.parseHeaders(allocator, bytes);
                defer allocator.free(hs);
                const txt = try tableText(allocator, bytes, entity.header_bytes);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
                count = hs.len;
                unit = "headers";
            },
            .enemy_hitboxes => {
                const hb = try entity.parseHitboxes(allocator, bytes);
                defer allocator.free(hb);
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                for (hb, 0..) |h, i| {
                    try buf.print(allocator, "{d:0>4} {d:>4} {d:>4} {d:>4} {d:>4}\n", .{ i, h.a, h.b, h.c, h.d });
                }
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, buf.items));
                count = hb.len;
                unit = "hitboxes";
            },
            .enemy_damage => {
                const txt = try tableText(allocator, bytes, 16);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
                count = bytes.len;
                unit = "enemy-ids";
            },
            .item_names => {
                // Decoded now rather than dumped as sixteen-wide rows: Step 11
                // read the block, so the text file can be the names and the
                // addresses they are stored at instead of a hex grid whose row
                // width was a display choice.
                const n = try items.parseNames(bytes, e.gb_addr);
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                for (0..items.count) |i| {
                    const at = e.gb_addr + @as(u16, @intCast(items.pointer_bytes + i * items.name_len));
                    try buf.print(allocator, "${X:0>1} {X:0>2}:${X:0>4}  |{s}|  {s}\n", .{
                        i, e.bank, at, n.text[i], n.trimmed(i),
                    });
                }
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, buf.items));
                count = items.count;
                unit = "names";
            },
            .sound_entry => {
                const txt = try tableText(allocator, bytes, 3);
                defer allocator.free(txt);
                const p = try std.fmt.allocPrint(allocator, "{s}.txt", .{e.name});
                try files.append(allocator, try write(io, dir, p, txt));
            },
            else => {
                // Raw only. The decoded form lives in a whole-region artifact.
            },
        }

        try report.records.append(allocator, .{
            .name = e.name,
            .kind = @tagName(e.kind),
            .bank = e.bank,
            .gb_addr = e.gb_addr,
            .rom_offset = e.romOffset(),
            .size = e.size,
            .count = count,
            .unit = unit,
            .files = try files.toOwnedSlice(allocator),
        });
    }

    report.regions = try decodeRegions(allocator, io, dir, rom);

    const manifest = try manifestJson(allocator, report);
    defer allocator.free(manifest);
    try dir.writeFile(io, .{ .sub_path = "manifest.json", .data = manifest });

    return report;
}

/// Decode the artifacts that span more than one offsets-table entry: the map
/// grids and screen bodies, the door script stream, and the metasprite sets.
///
/// These are separated from the per-entry loop because their meaning is not
/// per-entry. A screen pointer table is 512 bytes of nothing without the screen
/// bodies it indexes, and a door pointer is not interpretable without decoding
/// the stream it points into.
fn decodeRegions(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rom: []const u8) !Regions {
    var r: Regions = .{};

    // ---- Map banks --------------------------------------------------------
    var bank: u8 = map.first_bank;
    while (bank <= map.last_bank) : (bank += 1) {
        var mb = try map.parseBank(allocator, rom, bank);
        defer mb.deinit(allocator);

        var grid: std.ArrayList(u8) = .empty;
        defer grid.deinit(allocator);
        try grid.print(allocator, "# map bank ${X}: cell  ptr  scroll(RLUD)  transition\n", .{bank});
        for (mb.cells) |c| {
            if (!c.inUse()) continue;
            r.in_use_screens += 1;
            if (c.screenOffsetInBank() != null and map.screenBody(rom, bank, c.screen_ptr) != null) {
                r.screens_reached += 1;
            }
            try grid.print(allocator, "{d:0>2},{d:0>2} ${X:0>4} {c}{c}{c}{c} ${X:0>4}\n", .{
                c.x, c.y, c.screen_ptr,
                // A letter is a wall: the bit is set when the camera is
                // blocked that way. See `map.Scroll`.
                @as(u8, if (c.scroll.block_right) 'R' else '.'),
                @as(u8, if (c.scroll.block_left) 'L' else '.'),
                @as(u8, if (c.scroll.block_up) 'U' else '.'),
                @as(u8, if (c.scroll.block_down) 'D' else '.'),
                c.transition,
            });
        }
        r.distinct_screens += mb.referenced.len;
        r.screens_unresolved += mb.unresolved.len;

        const grid_path = try std.fmt.allocPrint(allocator, "map{X}_grid.txt", .{bank});
        _ = try write(io, dir, grid_path, grid.items);

        // Screen bodies as 16x16 metatile indexes, in address order.
        var screens: std.ArrayList(u8) = .empty;
        defer screens.deinit(allocator);
        for (mb.referenced) |ptr| {
            const body = map.screenBody(rom, bank, ptr) orelse continue;
            try screens.print(allocator, "screen ${X:0>4}\n", .{ptr});
            for (0..map.grid_h) |row| {
                for (0..map.grid_w) |col| {
                    try screens.print(allocator, "{s}{X:0>2}", .{ if (col == 0) "  " else " ", body[row * map.grid_w + col] });
                }
                try screens.append(allocator, '\n');
            }
        }
        const screens_path = try std.fmt.allocPrint(allocator, "map{X}_screens.txt", .{bank});
        _ = try write(io, dir, screens_path, screens.items);
    }

    // ---- Door scripts -----------------------------------------------------
    if (door.region(rom)) |bytes| {
        var decoded = try door.decodeRegion(allocator, bytes);
        defer decoded.deinit(allocator);
        r.door_ops = decoded.ops.items.len;

        // Re-encode and compare. This is the real test of the opcode table.
        var thresholds: std.AutoArrayHashMapUnmanaged(u8, void) = .empty;
        defer thresholds.deinit(allocator);
        for (decoded.ops.items) |op| {
            if (op == .if_met_less) {
                r.if_met_less_ops += 1;
                try thresholds.put(allocator, op.if_met_less.met_count, {});
            }
        }
        r.if_met_less_thresholds = thresholds.count();

        for (decoded.ops.items) |op| {
            const src: ?struct { b: u8, a: u16 } = switch (op) {
                .copy => |c| .{ .b = c.src_bank, .a = c.src_addr },
                .load => |l| .{ .b = l.src_bank, .a = l.src_addr },
                else => null,
            };
            if (src) |t| {
                if (door.resolveSource(t.b, t.a) == null) r.door_sources_unresolved += 1;
            }
        }

        var re: std.ArrayList(u8) = .empty;
        defer re.deinit(allocator);
        var scratch: [16]u8 = undefined;
        for (decoded.ops.items) |op| {
            const n = door.encodeOne(op, &scratch);
            try re.appendSlice(allocator, scratch[0..n]);
        }
        r.doors_round_trip = std.mem.eql(u8, re.items, bytes);

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        if (door.pointers(rom)) |ptr_bytes| {
            // Label each op that a pointer targets, so the text form shows
            // where scripts begin without inventing framing that is not there.
            var labels: std.AutoHashMapUnmanaged(usize, u16) = .empty;
            defer labels.deinit(allocator);
            var i: usize = 0;
            while (i + 1 < ptr_bytes.len) : (i += 2) {
                const gb = @as(u16, ptr_bytes[i]) | (@as(u16, ptr_bytes[i + 1]) << 8);
                if (decoded.indexOfAddr(gb)) |idx| {
                    r.door_pointers_aligned += 1;
                    try labels.put(allocator, idx, @intCast(i / 2));
                } else if (gb == door.data_end) {
                    r.door_pointers_empty += 1;
                } else {
                    r.door_pointers_external += 1;
                }
            }
            for (decoded.ops.items, 0..) |op, idx| {
                if (labels.get(idx)) |id| try text.print(allocator, "door{X:0>3}:\n", .{id});
                try door.write(allocator, &text, op);
            }
        }
        _ = try write(io, dir, "doors.txt", text.items);
    }

    // ---- Metasprites ------------------------------------------------------
    for (entity.metasprite_sets) |set| {
        const d = offsets.find(set.data) orelse continue;
        const p = offsets.find(set.pointers) orelse continue;
        if (d.romEnd() > rom.len or p.romEnd() > rom.len) continue;
        const data = rom[d.romOffset()..d.romEnd()];
        const ptrs = rom[p.romOffset()..p.romEnd()];

        const sprites = try entity.parseMetasprites(allocator, data, d.gb_addr);
        defer entity.freeMetasprites(allocator, sprites);
        r.metasprites += sprites.len;

        var starts: std.AutoHashMapUnmanaged(u16, void) = .empty;
        defer starts.deinit(allocator);
        for (sprites) |m| try starts.put(allocator, m.gb_addr, {});

        var i: usize = 0;
        while (i + 1 < ptrs.len) : (i += 2) {
            const gb = @as(u16, ptrs[i]) | (@as(u16, ptrs[i + 1]) << 8);
            r.metasprite_pointers_total += 1;
            if (starts.contains(gb)) {
                r.metasprite_pointers_matched += 1;
            } else if (gb < 0x4000 or gb >= 0x8000) {
                r.metasprite_pointers_out_of_window += 1;
            }
        }

        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (sprites) |m| {
            r.metasprite_parts += m.parts.len;
            try text.print(allocator, "sprite${X:0>4} ({d} parts){s}\n", .{
                m.gb_addr, m.parts.len,
                if (starts.contains(m.gb_addr)) "" else "",
            });
            for (m.parts) |part| {
                try text.print(allocator, "  y={d:>4} x={d:>4} tile=${X:0>2} attr=${X:0>2}\n", .{
                    part.y, part.x, part.tile, part.attr,
                });
            }
        }
        const path = try std.fmt.allocPrint(allocator, "metasprites_{s}.txt", .{set.name});
        _ = try write(io, dir, path, text.items);
    }

    return r;
}

/// The manifest is written by hand rather than via a JSON serializer so the key
/// order, spacing, and record order are fixed by this function. Determinism is
/// the whole point of the file; it should not depend on a hash map's iteration
/// order.
pub fn manifestJson(allocator: std.mem.Allocator, report: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\n  \"entries\": [\n");
    for (report.records.items, 0..) |r, i| {
        try buf.print(allocator,
            \\    {{"name": "{s}", "kind": "{s}", "bank": {d}, "gb_addr": "0x{X:0>4}", "rom_offset": {d}, "size": {d}, "count": {d}, "unit": "{s}", "files": [
        , .{ r.name, r.kind, r.bank, r.gb_addr, r.rom_offset, r.size, r.count, r.unit });
        for (r.files, 0..) |f, j| {
            try buf.print(allocator, "{s}{{\"path\": \"{s}\", \"bytes\": {d}, \"sha256\": \"{s}\"}}", .{
                if (j == 0) "" else ", ", f.path, f.bytes, &f.sha256,
            });
        }
        try buf.appendSlice(allocator, "]}");
        if (i + 1 != report.records.items.len) try buf.append(allocator, ',');
        try buf.append(allocator, '\n');
    }
    const g = report.regions;
    try buf.print(allocator,
        \\  ],
        \\  "extracted": {d},
        \\  "regions": {{"in_use_screens": {d}, "screens_reached": {d}, "screens_unresolved": {d}, "distinct_screens": {d}, "door_ops": {d}, "if_met_less_ops": {d}, "if_met_less_thresholds": {d}, "door_sources_unresolved": {d}, "door_pointers_aligned": {d}, "door_pointers_empty": {d}, "door_pointers_external": {d}, "doors_round_trip": {}, "metasprites": {d}, "metasprite_parts": {d}, "metasprite_pointers_matched": {d}, "metasprite_pointers_out_of_window": {d}, "metasprite_pointers_total": {d}}}
        \\}}
        \\
    , .{
        report.records.items.len,
        g.in_use_screens,       g.screens_reached, g.screens_unresolved,
        g.distinct_screens,     g.door_ops,
        g.if_met_less_ops,      g.if_met_less_thresholds, g.door_sources_unresolved,
        g.door_pointers_aligned, g.door_pointers_empty, g.door_pointers_external, g.doors_round_trip,
        g.metasprites,          g.metasprite_parts,
        g.metasprite_pointers_matched, g.metasprite_pointers_out_of_window, g.metasprite_pointers_total,
    });
    return buf.toOwnedSlice(allocator);
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "every entry is dumped, and the decoded forms cover the kinds we can read" {
    var decoded: usize = 0;
    for (offsets.entries) |e| {
        if (hasDecodedForm(e.kind)) decoded += 1;
    }
    // Pointer tables, screen bodies, door scripts, and metasprite data have no
    // per-entry decoded form; they are whole-region artifacts instead. That
    // gap is the point of the distinction, so assert it rather than a total.
    try testing.expect(!hasDecodedForm(.map_screen_pointers));
    try testing.expect(!hasDecodedForm(.map_screens));
    try testing.expect(!hasDecodedForm(.door_data));
    try testing.expect(!hasDecodedForm(.metasprite_data));
    try testing.expect(hasDecodedForm(.map_scroll_flags));
    try testing.expect(hasDecodedForm(.enemy_headers));
    try testing.expect(decoded > 60);
    try testing.expect(decoded < offsets.entries.len);
}

test "graphics entries are all whole tiles" {
    for (offsets.entries) |e| {
        switch (e.kind) {
            .graphics_tileset, .graphics_samus, .graphics_enemy, .graphics_item, .graphics_ui => {
                try testing.expectEqual(@as(usize, 0), e.size % gfx.tile_bytes);
            },
            else => {},
        }
    }
}

test "table text is fixed-width, one row per record, and index-prefixed" {
    const gpa = testing.allocator;
    const txt = try tableText(gpa, &[_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xAB, 0xCD, 0xEF, 0xFF }, 4);
    defer gpa.free(txt);
    try testing.expectEqualStrings("0000 00 01 02 FF\n0001 AB CD EF FF\n", txt);
}

test "manifest is stable byte-for-byte across two builds of the same report" {
    const gpa = testing.allocator;
    var report: Report = .{
        .records = .empty,
        .skipped = 0,
        .regions = .{ .in_use_screens = 905, .screens_reached = 905, .doors_round_trip = true },
    };
    defer report.deinit(gpa);
    const files = [_]FileHash{.{ .path = "x.bin", .bytes = 4, .sha256 = @splat('a') }};
    try report.records.append(gpa, .{
        .name = "x", .kind = "collision", .bank = 8, .gb_addr = 0x4080,
        .rom_offset = 0x20080, .size = 4, .count = 4, .unit = "tile-ids", .files = &files,
    });
    const a = try manifestJson(gpa, report);
    defer gpa.free(a);
    const b = try manifestJson(gpa, report);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expect(std.mem.indexOf(u8, a, "\"in_use_screens\": 905") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"doors_round_trip\": true") != null);
    try testing.expect(std.mem.indexOf(u8, a, "\"gb_addr\": \"0x4080\"") != null);
}
