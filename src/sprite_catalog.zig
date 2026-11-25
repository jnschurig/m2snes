//! The sprite catalogue, `src/data/sprite_catalog.zon` (sprite editor Step 4):
//! enemy names and the sheets the door walk can't find, maintained by hand;
//! and `src/data/sprite_frames.zon`, the frame names, groups and sheet choices
//! the sprite editor writes. No ROM bytes: ids, AIs and names only.
const std = @import("std");

pub const Frame = struct {
    /// Which sprite table the id indexes: "enemy" (`metasprite_enemies`).
    set: []const u8 = "enemy",
    id: u16,
    name: ?[]const u8 = null,
    group: ?[]const u8 = null,
    /// The sheet chosen for a frame the model can't resolve.
    sheet: ?[]const u8 = null,
};

pub const Catalog = struct {
    enemy_names: []const struct { id: u8, name: []const u8 },
    ai_names: []const struct { ai: u16, name: []const u8 },
    ai_sheets: []const struct { ai: u16, sheet: []const u8 },
    id_sheets: []const struct { lo: u8, hi: u8, sheet: []const u8 },
    species_pairs: []const [2]u16,
    item_names: []const []const u8,
};

pub const data: Catalog = @import("data/sprite_catalog.zon");

/// `sprite_frames.zon`'s shape. The sprite editor writes it whole
/// (`sprite_editor.writeFrames`).
pub const FrameData = struct { frames: []const Frame = &.{} };

/// The editor's frame names, groups and sheet choices.
pub const frames: []const Frame = @as(FrameData, @import("data/sprite_frames.zon")).frames;

/// A sprite's enemy, by its id where a species owns it (`enemy_names`), else by
/// the AI that spawns it (`ai_names`, M2RoS's routine names).
pub fn enemyName(id: u8, ai: u16) ?[]const u8 {
    for (data.enemy_names) |e| if (e.id == id) return e.name;
    for (data.ai_names) |e| if (e.ai == ai) return e.name;
    return null;
}

/// The sheet an AI's enemy is drawn with where the door walk can't say.
pub fn sheetOfAi(ai: u16) ?[]const u8 {
    for (data.ai_sheets) |e| if (e.ai == ai) return e.sheet;
    return null;
}

/// Whether two AIs drive one species: the same routine, or a `species_pairs`
/// pair.
pub fn sameSpecies(x: u16, y: u16) bool {
    if (x == y) return true;
    for (data.species_pairs) |p| if ((x == p[0] and y == p[1]) or (x == p[1] and y == p[0])) return true;
    return false;
}

/// Item `n`'s name: `ITEM`'s operand less one, the item orb's sprite id
/// `$80 + 2n`.
pub fn itemName(n: usize) ?[]const u8 {
    return if (n < data.item_names.len) data.item_names[n] else null;
}

/// The sheet `id_sheets` gives a sprite id, if any.
pub fn sheetOfId(id: u8) ?[]const u8 {
    for (data.id_sheets) |r| if (id >= r.lo and id <= r.hi) return r.sheet;
    return null;
}

/// Whether an `id_sheets` range starts at `id`: it starts a run of its own.
pub fn startsIdRange(id: u8) bool {
    for (data.id_sheets) |r| if (id == r.lo) return true;
    return false;
}

const testing = std.testing;

test "names: an id's species beats its AI's, and an unknown pair has none" {
    try testing.expectEqualStrings("Hornoad", enemyName(0x14, 0x61DB).?);
    try testing.expectEqualStrings("hopper", enemyName(0x15, 0x61DB).?);
    try testing.expect(enemyName(0x15, 0x0000) == null);
}

test "sheets: by id range first, by AI for the Metroids" {
    try testing.expectEqualStrings("gfx_enemiesC", sheetOfId(0x5E).?);
    try testing.expect(sheetOfId(0x65) == null);
    try testing.expect(startsIdRange(0x5C) and !startsIdRange(0x5D));
    try testing.expectEqualStrings("gfx_metAlpha", sheetOfAi(0x7A4F).?);
    try testing.expect(sheetOfAi(0x61DB) == null);
}

test "species: a routine is its own species, and a pair is one either way" {
    try testing.expect(sameSpecies(0x61DB, 0x61DB));
    try testing.expect(sameSpecies(0x58DE, 0x57DE));
    try testing.expect(!sameSpecies(0x57DE, 0x60AB));
}
