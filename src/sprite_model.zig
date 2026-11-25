//! The sprite model (sprite editor Steps 4-5): every sprite tile the cart
//! converts, the sheets that hold them, what object VRAM holds while each
//! sprite is drawn, and the frames (metasprites) the game draws: Samus, the
//! enemies, Metroids and bosses, the items and drops. `zig build swatch-full`
//! draws the enemy frames as `enemy-swatches.html` (`assembleSprites`); the
//! sprite editor serves `build`'s model.
const std = @import("std");
const door = @import("door.zig");
const roster = @import("roster.zig");
const warp = @import("warp.zig");
const offsets = @import("offsets.zig");
const entity = @import("entity.zig");
const sprites = @import("sprites.zig");
const full_slots = @import("full_slots.zig");
const snes_convert = @import("snes_convert.zig");
const sprite_edits = @import("sprite_edits.zig");
const swatch = @import("swatch_full.zig");
const catalog = @import("sprite_catalog.zig");

// ---- The enemy sprite table, resolved ----------------------------------------

/// A spawned sprite and the frames after it, up to the next spawned one: one
/// enemy's animation, drawn with one sheet. Sprite ids `head` to `end - 1`.
pub const Run = struct { head: usize, end: usize };

/// Neighbouring runs of one species, drawn with one sheet: `cands[sheet]`, or
/// null when no part of theirs is in the sheet's range ($B0-$EF), so any
/// sheet draws them the same.
pub const Block = struct { runs: []const Run, sheet: ?usize };

/// A sheet an enemy can be drawn with, as the object tiles hold it.
pub const Cand = struct { name: []const u8, key: u32, vram: *const swatch.ObjVram };

/// The enemy sprite table with each sprite's sheet (`resolveEnemies`).
pub const Enemies = struct {
    cands: []const Cand,
    /// Every run but the item orbs', in the order they were resolved.
    blocks: []const Block,
    /// The item orbs' runs, which no enemy sheet draws (`ITEM` loads theirs).
    orb_runs: []const Run,
    /// Each sprite id's parts, or null for a dead pointer.
    parts: []const ?[]const swatch.Part,
    /// Each sprite id's spawn records.
    spawns: []const usize,
    /// The AI of the records that spawn each sprite id (the last one's), or 0.
    ais: []const u16,
};

/// The enemy sprite table resolved to sheets. A spawn record votes for the
/// sheets its room can have loaded (`warp.settleSprites`, the door graph
/// walked from the new game); a spawned sprite and the unspawned frames after
/// it are one run, drawn with the voted sheet its parts join up best with
/// (`swatch_full.coherence`).
pub fn resolveEnemies(a: std.mem.Allocator, rom: []const u8) !Enemies {
    var decoded = try door.decodeRegion(a, door.region(rom) orelse return error.NoDoorData);
    _ = &decoded;
    var w = try roster.world(a, rom);
    const xs = try warp.crossings(a, rom, w, decoded);
    const per_room = try warp.settleSprites(a, rom, w, decoded, xs);
    _ = &w;

    // A record votes for each sheet its room can have loaded, a whole vote
    // shared among them.
    const recs = try roster.allRecords(a, rom);
    var votes: [256]std.AutoArrayHashMapUnmanaged(u32, f32) = @splat(.empty);
    const spawns = try a.alloc(usize, 256);
    @memset(spawns, 0);
    for (recs) |r| {
        spawns[r.sprite] += 1;
        const room = warp.roomAt(w, .{ .bank = r.bank, .cell = r.cell });
        if (room >= per_room.len) continue;
        const srcs = per_room[room].keys();
        for (srcs) |src| {
            const key = (@as(u32, src.bank) << 16) | src.addr;
            const g = try votes[r.sprite].getOrPut(a, key);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1.0 / @as(f32, @floatFromInt(srcs.len));
        }
    }

    // The enemy sprite table.
    const de = offsets.find("metasprite_enemies_data") orelse return error.UnresolvedSource;
    const data = rom[de.romOffset()..de.romEnd()];
    const recs_ms = try entity.parseMetasprites(a, data, de.gb_addr);
    const pe = offsets.find("metasprite_enemies_pointers") orelse return error.UnresolvedSource;
    const offs = try sprites.parsePointers(a, rom[pe.romOffset()..pe.romEnd()], de.gb_addr, data.len, recs_ms);

    // Every sheet an enemy can be drawn with, as the object tiles hold it:
    // the sheet at $B0-$EF, the common items at $F0-$FF.
    const ce = offsets.find("gfx_commonItems") orelse return error.UnresolvedSource;
    const cb = rom[ce.romOffset()..ce.romEnd()];
    var cands: std.ArrayList(Cand) = .empty;
    for (swatch.enemy_sheets) |spec| {
        if (spec.page != .full or !swatch.isEnemySheet(spec.name)) continue;
        const e = offsets.find(spec.name) orelse return error.UnresolvedSource;
        const bytes = rom[e.romOffset()..e.romEnd()];
        const v = try a.create(swatch.ObjVram);
        v.* = .{};
        for (0..@min(64, bytes.len / 16)) |t| {
            v.tiles[0xB0 + t] = bytes[t * 16 ..][0..16];
            v.slots[0xB0 + t] = full_slots.slot(spec.name, t) orelse 0;
        }
        for (0..cb.len / 16) |t| {
            v.tiles[0xF0 + t] = cb[t * 16 ..][0..16];
            v.slots[0xF0 + t] = full_slots.slot("gfx_commonItems", t) orelse 0;
        }
        try cands.append(a, .{ .name = spec.name, .key = (@as(u32, e.bank) << 16) | e.gb_addr, .vram = v });
    }

    const ais = try a.alloc(u16, offs.len);
    @memset(ais, 0);
    for (recs) |r| if (r.sprite < ais.len) {
        ais[r.sprite] = r.ai;
    };

    // Each sprite's parts, or null for a dead pointer.
    const all_parts = try a.alloc(?[]const swatch.Part, offs.len);
    for (offs, all_parts) |off, *ap| {
        ap.* = null;
        if (off == sprites.dead_offset) continue;
        const m = for (recs_ms) |r| {
            if (r.gb_addr == de.gb_addr + off) break r;
        } else continue;
        const parts = try a.alloc(swatch.Part, m.parts.len);
        for (m.parts, parts) |q, *o| o.* = .{ .y = q.y, .x = q.x, .tile = q.tile, .attr = q.attr };
        ap.* = parts;
    }

    // Runs: a spawned sprite and the frames after it, up to the next spawned
    // one, or the start of an `id_sheets` range.
    var runs: std.ArrayList(Run) = .empty;
    var orb_runs: std.ArrayList(Run) = .empty;
    var start: usize = 0;
    while (start < offs.len) {
        var end = start + 1;
        while (end < offs.len and spawns[end] == 0 and !catalog.startsIdRange(@intCast(end))) end += 1;
        try (if (ais[start] == item_orb_ai) &orb_runs else &runs).append(a, .{ .head = start, .end = end });
        start = end;
    }
    // The sheets a run may use: its id's or its AI's where the walk can't
    // say, else those its rooms can have loaded (none known: any).
    const allowedOf = struct {
        fn f(al: std.mem.Allocator, cs: []const Cand, vs: anytype, ai: u16, id: usize) !std.AutoArrayHashMapUnmanaged(u32, void) {
            var out: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
            if (catalog.sheetOfId(@intCast(id)) orelse catalog.sheetOfAi(ai)) |n| {
                for (cs) |c| if (std.mem.eql(u8, c.name, n)) try out.put(al, c.key, {});
                return out;
            }
            for (vs.keys()) |k| try out.put(al, k, {});
            if (out.count() == 0) for (cs) |c| try out.put(al, c.key, {});
            return out;
        }
    }.f;
    // Blocks: neighbouring runs of one species (`sprite_catalog.sameSpecies`:
    // crawler A and B are one species' two directions) are drawn with one
    // sheet, of those all of them allow. Of those, the one their parts join up
    // best with over the block; the door walk's vote breaks a tie.
    var blocks: std.ArrayList(Block) = .empty;
    var bi: usize = 0;
    while (bi < runs.items.len) {
        var allowed = try allowedOf(a, cands.items, votes[runs.items[bi].head], ais[runs.items[bi].head], runs.items[bi].head);
        var bj = bi + 1;
        while (bj < runs.items.len and runs.items[bj].head == runs.items[bj - 1].end and
            catalog.sameSpecies(ais[runs.items[bj].head], ais[runs.items[bj - 1].head])) : (bj += 1)
        {
            const next = try allowedOf(a, cands.items, votes[runs.items[bj].head], ais[runs.items[bj].head], runs.items[bj].head);
            var both: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
            for (allowed.keys()) |k| if (next.contains(k)) try both.put(a, k, {});
            if (both.count() == 0) break;
            allowed = both;
        }
        const block = runs.items[bi..bj];
        bi = bj;
        const head0 = block[0].head;
        var voted: ?u32 = null;
        var most: f32 = 0;
        for (votes[head0].keys(), votes[head0].values()) |k, v| if (v > most) {
            most = v;
            voted = k;
        };
        var best: usize = cands.items.len;
        var best_score: i32 = std.math.minInt(i32);
        for (cands.items, 0..) |c, ci| {
            if (!allowed.contains(c.key)) continue;
            var sc: i32 = 0;
            var any = false;
            for (block) |r| for (all_parts[r.head..r.end]) |ap| {
                const parts = ap orelse continue;
                for (parts) |q| if (q.tile >= 0xB0 and q.tile < 0xF0) {
                    any = true;
                };
                sc += swatch.coherence(parts, c.vram);
            };
            if (!any) break;
            if (sc > best_score or (sc == best_score and voted != null and c.key == voted.?)) {
                best_score = sc;
                best = ci;
            }
        }
        try blocks.append(a, .{ .runs = block, .sheet = if (best < cands.items.len) best else null });
    }
    return .{
        .cands = cands.items,
        .blocks = blocks.items,
        .orb_runs = orb_runs.items,
        .parts = all_parts,
        .spawns = spawns,
        .ais = ais,
    };
}

/// The enemy sprite table assembled, grouped by the sheet each sprite is
/// drawn with (`resolveEnemies`), each sprite as a PNG. A run with no part in
/// the sheet's range draws the same with any, and goes in its own group.
pub fn assembleSprites(a: std.mem.Allocator, rom: []const u8) ![]swatch.SpriteGroup {
    const en = try resolveEnemies(a, rom);
    const cands = en.cands;
    const Item = @typeInfo(@FieldType(swatch.SpriteGroup, "sprites")).pointer.child;
    var lists = try a.alloc(std.ArrayList(Item), cands.len + 1);
    for (lists) |*l| l.* = .empty;
    for (en.blocks) |b| {
        const best = b.sheet orelse cands.len;
        const v = if (best < cands.len) cands[best].vram else cands[0].vram;
        for (b.runs) |r| {
            const name = catalog.enemyName(@intCast(r.head), en.ais[r.head]);
            for (r.head..r.end) |id| {
                const parts = en.parts[id] orelse continue;
                const p = try swatch.spritePng(a, parts, v, .full, 0) orelse continue;
                try lists[best].append(a, .{ .id = @intCast(id), .png = p, .spawns = en.spawns[id], .name = if (id == r.head) name else null });
            }
            if (en.spawns[r.head] > 0) std.debug.print("sprite ${X:0>2}-${X:0>2} ai ${X:0>4} {s:<16} {d:>3} spawns, sheet {s}\n", .{ r.head, r.end - 1, en.ais[r.head], name orelse "?", en.spawns[r.head], if (best < cands.len) cands[best].name else "-" });
        }
    }
    var groups: std.ArrayList(swatch.SpriteGroup) = .empty;
    for (lists, 0..) |l, gi| {
        if (l.items.len == 0) continue;
        var n_spawns: usize = 0;
        for (l.items) |x| n_spawns += x.spawns;
        const name = if (gi < cands.len) cands[gi].name["gfx_".len..] else "common sprites";
        try groups.append(a, .{
            .title = name,
            .note = try std.fmt.allocPrint(a, "{d} sprites, {d} spawn records.", .{ l.items.len, n_spawns }),
            .sprites = l.items,
        });
    }
    return groups.toOwnedSlice(a);
}

/// `enAI_itemOrb`: the item orbs, which the enemy page leaves out.
const item_orb_ai: u16 = 0x4DD3;
/// The first item orb's sprite id. Item `n`'s orb is `$80 + 2n` and its
/// picture `$81 + 2n`, where `n` is `ITEM`'s operand less one, the item
/// window nibble whose four tiles it loads at `tile_dest`.
const item_orb_first: usize = 0x80;

// ---- The model ---------------------------------------------------------------

/// Where a unique tile sits in the ROM: one copy per ROM offset, with the
/// slot that copy is drawn in today (`full_slots.slotAt`), and the named
/// sheet and tile it is, if any.
pub const Copy = struct { rom_at: u32, slot: u3, sheet: ?u16 = null, tile: u16 = 0 };

/// A sprite tile, one per original Game Boy content (`sprite_edits.tileKey`):
/// what an edit is keyed on.
pub const Tile = struct {
    key: u64,
    gb: *const [16]u8,
    copies: []const Copy,
    /// Drawn on the 2bpp background too, as its shades: a BG twin of a `spr`
    /// window or `ITEM`'s, the credits' objects, or Samus's `$80-$AF`
    /// (`UploadSamusBgTwin`).
    twin: bool,
    /// Its copies are drawn in different slots today (`conflicts`).
    conflict: bool,
};

/// A named sheet (an offsets entry the converter makes a `chr_obj` asset of):
/// its tiles in order, as indices into `Model.tiles`.
pub const Sheet = struct { name: []const u8, title: []const u8, rom_at: u32, tiles: []const u32 };

/// An object VRAM tile: the unique tile loaded there and the slot it is drawn
/// in.
pub const Slotted = struct { tile: u32, slot: u3 };

/// What the object tiles hold while a frame is drawn, and how its parts take
/// their palettes (`full_slots.objAttr` through `page`; `suit` for Samus).
pub const View = struct {
    name: []const u8,
    title: []const u8,
    page: full_slots.ObjPage,
    suit: u1 = 0,
    vram: [256]?Slotted = @splat(null),
};

pub const FrameSet = enum { samus, enemy };

/// A metasprite the game draws, with the view it is drawn in: null when the
/// model can't tell (no part is loaded in any view it was given), and the
/// sprite catalogue's sheet choice wins over the model's.
pub const Frame = struct {
    set: FrameSet,
    id: u8,
    parts: []const swatch.Part,
    view: ?u16,
    name: ?[]const u8 = null,
    group: ?[]const u8 = null,
    spawns: usize = 0,
};

pub const Model = struct {
    tiles: []const Tile,
    sheets: []const Sheet,
    views: []const View,
    frames: []const Frame,
    /// Tiles whose copies are drawn in different slots today, blank tiles
    /// aside (their slot shows nothing), as indices into `tiles`.
    conflicts: []const u32,

    pub fn viewIndex(self: Model, name: []const u8) ?u16 {
        for (self.views, 0..) |v, i| if (std.mem.eql(u8, v.name, name)) return @intCast(i);
        return null;
    }

    pub fn frame(self: Model, set: FrameSet, id: u8) ?*const Frame {
        for (self.frames) |*f| if (f.set == set and f.id == id) return f;
        return null;
    }
};

/// The Game Boy ids Samus's sheet fills ($8000-$8AFF) and of those, the ones
/// the background reads too (the engine's `!SAMUS_TWIN_FIRST`/`LAST`).
const samus_tiles: usize = 0xB0;
const samus_twin_first: usize = 0x80;

/// The model, from `assets` (`snes_convert.run`'s) and the ROM they came from,
/// with `overrides`' names, groups and sheet choices (`catalog.frames`; the
/// sprite editor passes none and applies its own). Allocates from `a` without
/// freeing: pass an arena.
pub fn build(a: std.mem.Allocator, rom: []const u8, assets: []const snes_convert.Asset, overrides: []const catalog.Frame) !Model {
    // ---- Unique tiles: every chunk of every `chr_obj` asset ----------------
    const Acc = struct { copies: std.ArrayList(Copy) = .empty, twin: bool = false };
    var by_key: std.AutoArrayHashMapUnmanaged(u64, Acc) = .empty;
    // ROM offset -> (tile, copy).
    var at_off: std.AutoHashMapUnmanaged(u32, [2]u32) = .empty;
    for (assets) |s| {
        if (s.kind != .chr_obj) continue;
        for (0..s.gb_bytes / 16) |t| {
            const o: u32 = @intCast(s.rom_at + t * 16);
            if (at_off.contains(o)) continue;
            const g = try by_key.getOrPut(a, sprite_edits.tileKey(rom[o..][0..16]));
            if (!g.found_existing) g.value_ptr.* = .{};
            try g.value_ptr.copies.append(a, .{ .rom_at = o, .slot = full_slots.slotAt(o) });
            try at_off.put(a, o, .{ @intCast(g.index), @intCast(g.value_ptr.copies.items.len - 1) });
        }
    }
    for (assets) |s| {
        if (!s.twin) continue;
        for (0..s.gb_bytes / 16) |t| {
            const acc = by_key.getPtr(sprite_edits.tileKey(rom[s.rom_at + t * 16 ..][0..16])) orelse continue;
            acc.twin = true;
        }
    }
    const power = offsets.find("gfx_samusPowerSuit") orelse return error.UnresolvedSource;
    for (samus_twin_first..samus_tiles) |t| {
        const acc = by_key.getPtr(sprite_edits.tileKey(rom[power.romOffset() + t * 16 ..][0..16])) orelse return error.MissingTile;
        acc.twin = true;
    }

    // ---- Named sheets ------------------------------------------------------
    var sheets: std.ArrayList(Sheet) = .empty;
    for (assets) |s| {
        if (s.kind != .chr_obj or offsets.find(s.name) == null) continue;
        for (sheets.items) |x| {
            if (std.mem.eql(u8, x.name, s.name)) break;
        } else {
            const si: u16 = @intCast(sheets.items.len);
            const ts = try a.alloc(u32, s.gb_bytes / 16);
            for (ts, 0..) |*o, t| {
                const tc = at_off.get(@intCast(s.rom_at + t * 16)).?;
                o.* = tc[0];
                const c = &by_key.values()[tc[0]].copies.items[tc[1]];
                if (c.sheet == null) {
                    c.sheet = si;
                    c.tile = @intCast(t);
                }
            }
            const title = for (swatch.enemy_sheets) |spec| {
                if (std.mem.eql(u8, spec.name, s.name)) break spec.title;
            } else s.name;
            try sheets.append(a, .{ .name = s.name, .title = title, .rom_at = @intCast(s.rom_at), .tiles = ts });
        }
    }

    // ---- Tiles and conflicts -----------------------------------------------
    const tiles = try a.alloc(Tile, by_key.count());
    var conflicts: std.ArrayList(u32) = .empty;
    for (by_key.keys(), by_key.values(), tiles, 0..) |k, acc, *t, i| {
        const cs = acc.copies.items;
        const gb = rom[cs[0].rom_at..][0..16];
        var differ = false;
        for (cs[1..]) |c| differ = differ or c.slot != cs[0].slot;
        const conflict = differ and !std.mem.allEqual(u8, gb, 0);
        if (conflict) try conflicts.append(a, @intCast(i));
        t.* = .{ .key = k, .gb = gb, .copies = cs, .twin = acc.twin, .conflict = conflict };
    }

    // ---- Views -------------------------------------------------------------
    const Loader = struct {
        at_off: *const std.AutoHashMapUnmanaged(u32, [2]u32),
        fn load(self: @This(), v: *View, first: usize, rom_at: usize, count: usize) !void {
            for (0..count) |i| {
                const o: u32 = @intCast(rom_at + i * 16);
                const tc = self.at_off.get(o) orelse return error.MissingTile;
                v.vram[first + i] = .{ .tile = tc[0], .slot = full_slots.slotAt(o) };
            }
        }
    };
    const ld: Loader = .{ .at_off = &at_off };
    const common = offsets.find("gfx_commonItems") orelse return error.UnresolvedSource;
    const varia = offsets.find("gfx_samusVariaSuit") orelse return error.UnresolvedSource;
    var views: std.ArrayList(View) = .empty;
    // Samus, in each suit: her sheet at $00-$AF.
    for ([_]offsets.Entry{ power, varia }, 0..) |e, suit| {
        var v: View = .{ .name = e.name, .title = if (suit == 0) "Samus, Power Suit" else "Samus, Varia Suit", .page = .samus, .suit = @intCast(suit) };
        try ld.load(&v, 0, e.romOffset(), samus_tiles);
        try views.append(a, v);
    }
    const power_view: u16 = 0;
    // Every other object: Samus's sheet below $B0 as the Game Boy keeps it,
    // the common items at $F0.
    const base = blk: {
        var v: View = .{ .name = "", .title = "", .page = .full };
        try ld.load(&v, 0, power.romOffset(), samus_tiles);
        try ld.load(&v, 0xF0, common.romOffset(), common.size / 16);
        break :blk v;
    };
    // An enemy sheet at $B0-$EF.
    const en = try resolveEnemies(a, rom);
    const first_cand: u16 = @intCast(views.items.len);
    for (en.cands) |c| {
        const e = offsets.find(c.name).?;
        var v = base;
        v.name = c.name;
        v.title = for (swatch.enemy_sheets) |spec| {
            if (std.mem.eql(u8, spec.name, c.name)) break spec.title;
        } else c.name;
        try ld.load(&v, 0xB0, e.romOffset(), @min(64, e.size / 16));
        try views.append(a, v);
    }
    // No enemy sheet: the drops and whatever draws only from the common items.
    const common_view: u16 = @intCast(views.items.len);
    {
        var v = base;
        v.name = "common";
        v.title = "Common sprites";
        try views.append(a, v);
    }
    // An item's: `ITEM` loads the orb at `orb_dest` and the item window's
    // nibble at `tile_dest`.
    const arm = snes_convert.itemArm(rom) orelse return error.UnresolvedSource;
    const first_item: u16 = @intCast(views.items.len);
    for (0..snes_convert.item_nibbles) |n| {
        var v = base;
        v.name = try std.fmt.allocPrint(a, "item_{d}", .{n});
        v.title = try std.fmt.allocPrint(a, "Item: {s}", .{catalog.itemName(n) orelse v.name});
        try ld.load(&v, (arm.orb_dest - 0x8000) / 16, romOf(arm.bank, arm.orb_src), arm.orb_len / 16);
        try ld.load(&v, (arm.tile_dest - 0x8000) / 16, romOf(arm.bank, arm.tile_base) + n * arm.tile_len, arm.tile_len / 16);
        try views.append(a, v);
    }

    // ---- Frames ------------------------------------------------------------
    var frames: std.ArrayList(Frame) = .empty;
    {
        const de = offsets.find("metasprite_samus_data") orelse return error.UnresolvedSource;
        const data = rom[de.romOffset()..de.romEnd()];
        const ms = try entity.parseMetasprites(a, data, de.gb_addr);
        const pe = offsets.find("metasprite_samus_pointers") orelse return error.UnresolvedSource;
        const offs = try sprites.parsePointers(a, rom[pe.romOffset()..pe.romEnd()], de.gb_addr, data.len, ms);
        for (offs, 0..) |off, id| {
            if (off == sprites.dead_offset) continue;
            const m = for (ms) |r| {
                if (r.gb_addr == de.gb_addr + off) break r;
            } else continue;
            const parts = try a.alloc(swatch.Part, m.parts.len);
            for (m.parts, parts) |q, *o| o.* = .{ .y = q.y, .x = q.x, .tile = q.tile, .attr = q.attr };
            try frames.append(a, .{ .set = .samus, .id = @intCast(id), .parts = parts, .view = power_view, .group = "Samus" });
        }
    }
    for (en.blocks) |b| {
        const view: u16 = if (b.sheet) |s| first_cand + @as(u16, @intCast(s)) else common_view;
        for (b.runs) |r| {
            const name = catalog.enemyName(@intCast(r.head), en.ais[r.head]);
            const group = name orelse try std.fmt.allocPrint(a, "sprite ${X:0>2}", .{r.head});
            for (r.head..r.end) |id| {
                const parts = en.parts[id] orelse continue;
                try frames.append(a, .{ .set = .enemy, .id = @intCast(id), .parts = parts, .view = view, .name = if (id == r.head) name else null, .group = group, .spawns = en.spawns[id] });
            }
        }
    }
    for (en.orb_runs) |r| {
        if (r.head < item_orb_first or (r.head - item_orb_first) / 2 >= snes_convert.item_nibbles) return error.UnexpectedItemOrb;
        const n = (r.head - item_orb_first) / 2;
        const group = catalog.itemName(n) orelse try std.fmt.allocPrint(a, "item {d}", .{n});
        for (r.head..r.end) |id| {
            const parts = en.parts[id] orelse continue;
            try frames.append(a, .{ .set = .enemy, .id = @intCast(id), .parts = parts, .view = first_item + @as(u16, @intCast(n)), .group = group, .spawns = en.spawns[id] });
        }
    }

    var model: Model = .{ .tiles = tiles, .sheets = sheets.items, .views = views.items, .frames = frames.items, .conflicts = conflicts.items };
    // A frame none of whose parts the view loads is unresolved.
    for (frames.items) |*f| {
        const v = &model.views[f.view.?];
        for (f.parts) |q| {
            if (v.vram[q.tile] != null) break;
        } else f.view = null;
    }
    // The overrides' names, groups and sheet choices win.
    for (overrides) |cf| {
        const set = std.meta.stringToEnum(FrameSet, cf.set) orelse return error.UnknownFrameSet;
        for (frames.items) |*f| {
            if (f.set != set or f.id != cf.id) continue;
            if (cf.name) |n| f.name = n;
            if (cf.group) |g| f.group = g;
            if (cf.sheet) |s| f.view = model.viewIndex(s) orelse return error.UnknownSheet;
        }
    }
    return model;
}

fn romOf(bank: u8, addr: u16) usize {
    return @as(usize, bank) * offsets.bank_size + (addr & 0x3FFF);
}

// ---- Tests -------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    rom: []const u8,
    set: snes_convert.Set,
    model: Model,

    fn init() !?*Fixture {
        const testrom = @import("testrom");
        const f = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(f);
        f.arena = .init(testing.allocator);
        errdefer f.arena.deinit();
        const a = f.arena.allocator();
        f.rom = try testrom.load(a) orelse {
            f.arena.deinit();
            testing.allocator.destroy(f);
            return null;
        };
        f.set = try snes_convert.run(a, f.rom);
        f.model = try build(a, f.rom, f.set.assets, catalog.frames);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.set.deinit();
        f.arena.deinit();
        testing.allocator.destroy(f);
    }

    fn keyAt(f: *const Fixture, at: usize) u64 {
        return sprite_edits.tileKey(f.rom[at..][0..16]);
    }
};

test "model: Samus and an item frame resolve to their sheets" {
    const f = try Fixture.init() orelse return error.SkipZigTest;
    defer f.deinit();
    const m = f.model;

    // Samus faces the screen in her Power Suit's sheet, every part loaded.
    const s = m.frame(.samus, sprites.face_screen).?;
    try testing.expectEqualStrings("gfx_samusPowerSuit", m.views[s.view.?].name);
    try testing.expectEqual(full_slots.ObjPage.samus, m.views[s.view.?].page);
    const power = offsets.find("gfx_samusPowerSuit").?;
    for (s.parts) |q| {
        const t = m.views[s.view.?].vram[q.tile].?;
        try testing.expectEqual(f.keyAt(power.romOffset() + @as(usize, q.tile) * 16), m.tiles[t.tile].key);
    }

    // The first item's picture ($81) is `gfx_items`' first four tiles.
    const it = m.frame(.enemy, item_orb_first + 1).?;
    try testing.expectEqualStrings("item_0", m.views[it.view.?].name);
    const items = offsets.find("gfx_items").?;
    for (it.parts) |q| {
        const t = m.views[it.view.?].vram[q.tile].?;
        try testing.expectEqual(f.keyAt(items.romOffset() + (@as(usize, q.tile) - 0xB4) * 16), m.tiles[t.tile].key);
    }
    // And its orb the item orb's.
    const orb = m.frame(.enemy, item_orb_first).?;
    try testing.expectEqual(it.view, orb.view);

    // An enemy keeps the sheet `swatch-full` draws it with: Hornoad.
    const h = m.frame(.enemy, 0x14).?;
    try testing.expectEqualStrings("Hornoad", h.name.?);
    try testing.expect(h.view != null);
}

test "model: every sprite tile the converter edits is a model tile, and twins are marked" {
    const f = try Fixture.init() orelse return error.SkipZigTest;
    defer f.deinit();
    const m = f.model;
    var keys: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer keys.deinit(testing.allocator);
    for (m.tiles, 0..) |t, i| try keys.put(testing.allocator, t.key, @intCast(i));
    try testing.expectEqual(m.tiles.len, keys.count());
    for (f.set.assets) |s| {
        if (s.kind != .chr_obj and !s.twin) continue;
        for (0..s.gb_bytes / 16) |t| {
            const i = keys.get(f.keyAt(s.rom_at + t * 16)).?;
            if (s.twin) try testing.expect(m.tiles[i].twin);
        }
    }
    // Samus's $80-$AF are the background's too; $00 is not.
    const power = offsets.find("gfx_samusPowerSuit").?;
    try testing.expect(m.tiles[keys.get(f.keyAt(power.romOffset() + 0x80 * 16)).?].twin);
    // Each named sheet lists its tiles in order.
    for (m.sheets) |sh| for (sh.tiles, 0..) |ti, t| {
        try testing.expectEqual(f.keyAt(sh.rom_at + t * 16), m.tiles[ti].key);
    };
}

test "model: the conflict list is stable against the ROM" {
    const f = try Fixture.init() orelse return error.SkipZigTest;
    defer f.deinit();
    const m = f.model;
    var h = std.hash.Wyhash.init(0);
    for (m.conflicts) |ci| {
        const t = m.tiles[ci];
        try testing.expect(t.conflict and t.copies.len >= 2);
        try testing.expect(!std.mem.allEqual(u8, t.gb, 0));
        h.update(std.mem.asBytes(&t.key));
    }
    // 2026-11-24: six title/credits glyphs (the title in slot 3, the font
    // and credits digits in 7), one Samus tile also in `gfx_surfaceSPR`, one
    // `gfx_enemiesA` tile twice, and one tile of both the Zeta's and the
    // Omega's sheets.
    try testing.expectEqual(@as(usize, 9), m.conflicts.len);
    try testing.expectEqual(@as(u64, 0x3D62A1C28E37CACD), h.final());
}
