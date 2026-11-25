//! The `full` scheme's palette assignment: which palette slot each tile
//! and sprite is drawn in (colorization F2).
//!
//! **Generated** by `zig build full-assign` from EJRTQ's GBC colorization of
//! Metroid II (v1.3, on romhacking.net), except the hand-edited section
//! at the end. `zig build full-assign -- check` diffs this file against a fresh
//! extraction. `docs/colorization.md` describes the model and names the
//! hack. (Not by its number here: the leak check would read it as a
//! colour value.)
//!
//! It holds slot numbers and tile ids only: no colours and no ROM bytes.
//! A slot is 0-7. The colours each slot gets are `colors.zig`'s.
//!
//! A sprite tile's slot here is its derived one: the sprite editor's
//! `src/data/sprite_edits.zon` may override it per unique tile
//! (`full_slots.blob`).

const std = @import("std");

pub const Layer = enum { bg, obj };

/// A graphics region of `offsets.zig`, and one slot digit per 16-byte tile,
/// in ROM order. Sprites and the background share them. `seen` is what
/// the recording showed of each tile (`zig build full-assign -- cover`): `.`
/// never, so its slot is unobserved; `b` on the background or window
/// only; `s` as a sprite only; `+` both. Empty: coverage not run.
pub const Region = struct { name: []const u8, slots: []const u8, seen: []const u8 = "" };

/// An OBJ entry with the DMG OBP1 bit: slot `when` becomes `then`, any
/// other slot becomes `otherwise`.
pub const Obp1Swap = struct { when: u3, then: u3, otherwise: u3 };

/// Slots `a` and `b` of `layer` show the same colours for the shades in
/// `shades` (bit n: shade n), so tiles that look alike stay alike.
pub const LookAlike = struct { layer: Layer, a: u3, b: u3, shades: u4 };

/// An original tile id at an edited position, and the slots (bit n: slot
/// n) the ids EJRTQ shows there have. More than one bit is a conflict.
pub const Derived = struct { id: u8, slots: u8 };

/// A hand choice for an original tile id, with the reason.
pub const Choice = struct { id: u8, slot: u3, why: []const u8 };

/// The slot of tile `tile` of region `name`, or null if there is none.
pub fn slot(name: []const u8, tile: usize) ?u3 {
    for (regions) |r| {
        if (!std.mem.eql(u8, r.name, name)) continue;
        if (tile >= r.slots.len) return null;
        return @intCast(r.slots[tile] - '0');
    }
    return null;
}

/// The slot for original id `id` at an edited position: the hand choice
/// if there is one, else the derived slot if it is unique, else null.
pub fn editSlot(derived: []const Derived, choices: []const Choice, id: u8) ?u3 {
    for (choices) |c| if (c.id == id) return c.slot;
    for (derived) |d| {
        if (d.id != id) continue;
        if (@popCount(d.slots) != 1) return null;
        return @intCast(@ctz(d.slots));
    }
    return null;
}

pub fn hudSlot(id: u8) ?u3 {
    return editSlot(&hud, &hud_choices, id);
}

pub fn queenSlot(id: u8) ?u3 {
    return editSlot(&queen, &queen_choices, id);
}

pub const regions = [_]Region{
    .{
        .name = "gfx_titleScreen",
        .slots = "3333333333333333333333333333333333333333333333333333333333333333" ++
            "3333333777733333333333333333377777777777777774422333333333333307" ++
            "11111111111111171111111111111117",
        .seen = "bbbbbbbbbbbbbbbbbbb+bbbbbbb+bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbb+b++b++++b++bbbbbbbbbbbbbbsss.sssss.....s...b" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    },
    .{
        .name = "gfx_creditsFont",
        .slots = "777777777777777777777777773333772222222233333333",
        .seen = "bbbbbbbbbbbbbbbb.bbbb.b.bb...bbbbbbbbbbb..bbbbbb",
    },
    .{
        .name = "gfx_itemFont",
        .slots = "77777777777777777777777777777777",
        .seen = "+b+++.bbbbb++.++.+++bbb..b....bb",
    },
    .{
        .name = "gfx_creditsNumbers",
        .slots = "7777777777700005",
        .seen = "s.s...s...bss..b",
    },
    .{
        .name = "gfx_creditsSprTiles",
        .slots = "5575555555665555555555555555755557556655565555555555555755555556" ++
            "5555655550000555555557555555555556555565555655555555555555555566" ++
            "5555565555555550222222222222222222222222222222222222222222222222" ++
            "222222222222222222222222222222222222222222222233",
        .seen = "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss" ++
            "sssssssssssssssss..ssssssssssssssssssssssssssssssss............." ++
            "................ssssssssssssssssssssssssssssssssssssssssssssssss" ++
            "sssssssssssssssssss.ssssssssssssssssssssssssssss",
    },
    .{
        .name = "gfx_theEnd",
        .slots = "3333333333333300",
        .seen = "bbbbbbbbbbbbbb..",
    },
    .{
        .name = "gfx_cannonBeam",
        .slots = "66",
        .seen = "ss",
    },
    .{
        .name = "gfx_cannonMissile",
        .slots = "66",
        .seen = "ss",
    },
    .{
        .name = "gfx_beamIce",
        .slots = "33",
        .seen = "ss",
    },
    .{
        .name = "gfx_beamWave",
        .slots = "11",
        .seen = "ss",
    },
    .{
        .name = "gfx_beamSpazerPlasma",
        .slots = "55",
        .seen = "ss",
    },
    .{
        .name = "gfx_spinSpaceTop",
        .slots = "5555755",
        .seen = "sssssss",
    },
    .{
        .name = "gfx_spinSpaceBottom",
        .slots = "55755",
        .seen = "sssss",
    },
    .{
        .name = "gfx_spinScrewTop",
        .slots = "5555555",
        .seen = ".......",
    },
    .{
        .name = "gfx_spinScrewBottom",
        .slots = "55555",
        .seen = ".....",
    },
    .{
        .name = "gfx_spinSpaceScrewTop",
        .slots = "4443333",
        .seen = "sssssss",
    },
    .{
        .name = "gfx_spinSpaceScrewBottom",
        .slots = "44433",
        .seen = "sssss",
    },
    .{
        .name = "gfx_springBallTop",
        .slots = "44",
        .seen = "ss",
    },
    .{
        .name = "gfx_springBallBottom",
        .slots = "44",
        .seen = "ss",
    },
    .{
        .name = "gfx_samusPowerSuit",
        .slots = "5755745466575553555555556555555565555555545555556554555555556555" ++
            "5555555555555555555575555555555555755555555555555555555555544444" ++
            "444454444344444444111133330033737777777777333333",
        .seen = "sssssssssssssss.ssssssssssssssssssssssssssssssssssssss.sssssssss" ++
            "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss" ++
            "sssssssssssssss.ssssssssssssbbbbbbbbbbbbbbbssssb",
    },
    .{
        .name = "gfx_samusVariaSuit",
        .slots = "5755745466575553555555555555555565555555545555556554555555556555" ++
            "5555555555555555555575555555555555755555555555555555555555500000" ++
            "000000000000000000000000000000000000000000000000",
        .seen = "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss" ++
            "sssssssssssssssssssssssssssssssssssssssssssssssssssssssssss....." ++
            "................................................",
    },
    .{
        .name = "gfx_enemiesA",
        .slots = "4455557557555757555555555555555555541111111000000066666666644545",
        .seen = "ssssssssssssssssssssssssssssssssssssssssssssss....ss+sssssssssss",
    },
    .{
        .name = "gfx_enemiesB",
        .slots = "5555606640060000004444444440666406606006066661111111456666000054",
        .seen = "ssssssssss..ssssssssssssssssssssssssssssssssssssssssssssssssss.s",
    },
    .{
        .name = "gfx_enemiesC",
        .slots = "4444516666666655545545554533333333000005555555555555544454453333",
        .seen = "sssss.ssssssssssssssssssssssssssssssssssssssssssssssssssssss....",
    },
    .{
        .name = "gfx_enemiesD",
        .slots = "3311755555533333333334036616161611331113333333333554533330000111",
        .seen = "sssssssssssssssssssssss.ssssssss...s....sssssss.ssssssss........",
    },
    .{
        .name = "gfx_enemiesE",
        .slots = "3344345335532335455333444445535540455441344444444006605065006006",
        .seen = "sssssssssssssssssssssss..sssss.....sssssssssssssssssssssssssssss",
    },
    .{
        .name = "gfx_enemiesF",
        .slots = "3300554445555445445455455555050040444444444444400044444444444440",
        .seen = "ssssssssssssssssssssssssssssssssssssssssssssss......ssssssssss..",
    },
    .{
        .name = "gfx_arachnus",
        .slots = "4444555544554455545557555445555777500000000000000000000000000000",
        .seen = "sssssssssssssssssssssssssssssssssss.............................",
    },
    .{
        .name = "gfx_surfaceSPR",
        .slots = "0000666666777736444444444444444444444444444444447407664444444444",
        .seen = "ssssssssssbbbbb.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb+b",
    },
    .{
        .name = "gfx_plantBubbles",
        .slots = "4444000022223377727022272740666600662266660000000000000026625555" ++
            "0066667722222222000000005555555546666666666666266666666666667270",
        .seen = "bbbbbbbbbbbbbbbbbbbbbbbbbbb.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbb....bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    },
    .{
        .name = "gfx_ruinsInside",
        .slots = "7777222200003377444447744774477444444444444444441111000033333333" ++
            "2222000000224444777714146666662244777777773300006666666633404007",
        .seen = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    },
    .{
        .name = "gfx_queenBG",
        .slots = "2222226666666622222666666662262266622666226666226622226622262222" ++
            "2226225522222262222226600007677700000000000000000000000000000000",
        .seen = "bbbbbbbbbbb...bbbbbbbbbbbbbbbb.bbbbbbbbbbbb.bbbbbbbbbbbbbbbbbbb." ++
            "bbbbbbbbbbbbbb.bbbbbbbbbbbbb.bb............b........b..........b",
    },
    .{
        .name = "gfx_caveFirst",
        .slots = "4444000022222222337777007441333300007777722222222222000000000000" ++
            "0000222222220000777777770027266666600003772266722222666666662002",
        .seen = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbb..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb..bbbbbbbb",
    },
    .{
        .name = "gfx_surfaceBG",
        .slots = "2222222222202222444444444444444444444444444444444444027772002777" ++
            "2000777777002222222222222666006066666000000620024444444444444444",
        .seen = "............bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb....bbbbb...bbbbbbbbbbbbbbbbbbbb",
    },
    .{
        .name = "gfx_lavaCavesA",
        .slots = "0000000000007777655666665555555514105555414155550500445555757577" ++
            "7766555757566665555",
        .seen = "bb.b........bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.bbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbb...",
    },
    .{
        .name = "gfx_lavaCavesB",
        .slots = "3333777722227777655666665555555577775555222255552500005555757527" ++
            "7766555757566665555",
        .seen = ".....b.bbb..b...bbbbbbbbbbbb....bbbbbbbbbbbbbbbbbbbbbbbb..b.bbbb" ++
            "bbbb..bb.b.bbbb....",
    },
    .{
        .name = "gfx_lavaCavesC",
        .slots = "4444444400004444655666665555555566665555222255550541225555757527" ++
            "7766555757566665555",
        .seen = ".................bb......bb.....bbbbbbbbbbbbbbbbbbbbbb......bbbb" ++
            "bb....b..bb........",
    },
    .{
        .name = "gfx_items",
        .slots = "15116366414454555555555577775555333344445555",
        .seen = "ssssssssssssssssssssssssssssssssssssssss....",
    },
    .{
        .name = "gfx_itemOrb",
        .slots = "4444",
        .seen = "ssss",
    },
    .{
        .name = "gfx_commonItems",
        .slots = "3333555444433100",
        .seen = "ssssssssssssss.+",
    },
    .{
        .name = "gfx_metAlpha",
        .slots = "4000000644444406444005560004440400004444444405545500044000000004",
        .seen = "ssssssssss....ssssssssssssss...sssssssssssssssss....ssssssssssss",
    },
    .{
        .name = "gfx_metGamma",
        .slots = "4000444444444444444054444440404440004404444440444444660004444000",
        .seen = "sssssssss..sssssssss.ssss..sssss.ssssssss..sss........sss..sssss",
    },
    .{
        .name = "gfx_metZeta",
        .slots = "4404444444444400440444444444000064404404400455004044440000445500",
        .seen = "ssssssssssss.sssssssssssssssssssssssssssssssssssssss.ssssssss.ss",
    },
    .{
        .name = "gfx_metOmega",
        .slots = "4404444444404400440440600606445504454400660605554045440000405555",
        .seen = "ssssssssssssssssssssssssssssssssssssssssssssssss.sssssssss.sssss",
    },
    .{
        .name = "gfx_ruinsExt",
        .slots = "0000000022223377777777330044444444777707777222231443333377667777" ++
            "2222222266662720220066666641555555550233000066666666666622007777",
        .seen = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    },
    .{
        .name = "gfx_finalLab",
        .slots = "2222000000007777222222272222227222722222272227222027222722214414" ++
            "3322003327777777000077777277777277222202276222222222420022223244",
        .seen = "bbbbbbbbbbbbbbbb......b.....bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb..bbbbbbbbbbbbbbbbbbbb..bbb.bbbb",
    },
    .{
        .name = "gfx_queenSPR",
        .slots = "4666600066666624652260022226202262222212226622226626662224652222" ++
            "5522222622662620",
        .seen = "+bbbbs..........bbbbbs..........bbbbbb.........b..bbbb...b.....b" ++
            "ssb.b....b....bb",
    },
};

/// `10:41A0` (and `10:41CA`).
pub const obp1_swap: Obp1Swap = .{ .when = 3, .then = 1, .otherwise = 3 };

/// A frozen enemy's slot (`01:7B87`). The OBP1 swap does not override it.
pub const frozen_slot: u3 = 3;

/// Identical palettes, and the slots pixel-identical tiles of one
/// tileset are drawn in.
pub const look_alikes = [_]LookAlike{};

/// `hudBaseTilemap`'s original ids, from the ids EJRTQ shows there.
pub const hud = [_]Derived{
    .{ .id = 0x9E, .slots = 0b10000000 },
    .{ .id = 0x9F, .slots = 0b00001000 },
    .{ .id = 0xA0, .slots = 0b10000000 },
    .{ .id = 0xA3, .slots = 0b10000000 },
    .{ .id = 0xAF, .slots = 0b10001000 },
    .{ .id = 0xFF, .slots = 0b00000001 },
};

/// The Queen area's original ids (map F screens $FE), from the ids EJRTQ shows there.
pub const queen = [_]Derived{
    .{ .id = 0x9E, .slots = 0b10000000 },
    .{ .id = 0x9F, .slots = 0b00001000 },
    .{ .id = 0xAF, .slots = 0b10001000 },
    .{ .id = 0xFF, .slots = 0b00000001 },
};

// ---- Hand-edited below this line. `zig build full-assign` keeps it as it is. ----

/// Hand choices for the status bar's original ids (`hud`): one per
/// conflict the oracle reports, or to replace a derived slot.
pub const hud_choices = [_]Choice{
    .{ .id = 0xAF, .slot = 3, .why = af_why },
};

/// The same for the Queen area's ids (`queen`). Her room draws the status
/// bar on the background (map F screen $FE's bottom row), with the same edits.
pub const queen_choices = [_]Choice{
    .{ .id = 0xAF, .slot = 3, .why = af_why },
};

/// $AF is the status bar's solid shade-1 blank. EJRTQ shows $A9 (the digit
/// 9) where the original's blanks are digit fields, which the status bar
/// overwrites every frame with digits in their own slot, and $9D (an empty
/// energy tank) at the tank columns. Where it keeps $AF, $AF is in slot 3,
/// as it is in the source-tile table.
const af_why = "the blank's own slot; EJRTQ's other ids at $AF positions are digit placeholders and its empty-tank glyph";

/// A hand choice for tiles of one region (`regions`), with the reason:
/// they are drawn in `slot` whatever the derived slot says.
pub const TileChoice = struct { region: []const u8, tiles: []const u8, slot: u3, why: []const u8 };

/// The kinds of background tile `full` draws the same everywhere
/// (colorization F3, amended 2026-11-22), each in a slot of its own: the tiles
/// a tileset's collision table marks as hurting Samus (bit 3, `00:$2021`:
/// spikes and coral, red), as acid (bit 4, `00:$1EC5`: purple) and as the
/// liquid that slows her (bit 0, `00:$1EB5`: yellow). A tile with two bits
/// takes the first of those. The tile is the id: a tileset's graphics land at
/// `$9000`, ids `$00-$7F`. `full_slots`' tests hold the lists against the ROM.
pub const spike_slot: u3 = 1;
pub const acid_slot: u3 = 5;
pub const liquid_slot: u3 = 3;

/// Every other background tile leaves those three slots: where its derived
/// slot is one, it is drawn in this one instead (`full_slots.bgSlot`). So
/// 1 joins 0, 3 joins 2 and 5 joins 6. Objects keep their derived slots.
pub const bg_merge = [8]u3{ 0, 0, 2, 2, 4, 6, 6, 7 };

pub const tile_choices = [_]TileChoice{
    .{ .region = "gfx_plantBubbles", .tiles = &.{ 0x1C, 0x1D, 0x1E, 0x1F, 0x26, 0x27, 0x28, 0x29, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52, 0x53, 0x61, 0x62 }, .slot = spike_slot, .why = spike_why },
    .{ .region = "gfx_plantBubbles", .tiles = &.{ 0x67, 0x68, 0x70, 0x71, 0x72, 0x73 }, .slot = liquid_slot, .why = liquid_why },
    .{ .region = "gfx_ruinsInside", .tiles = &.{ 0x15, 0x16, 0x19, 0x1A }, .slot = spike_slot, .why = spike_why },
    .{ .region = "gfx_caveFirst", .tiles = &.{ 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x5E, 0x5F, 0x6D, 0x74, 0x75, 0x76, 0x77 }, .slot = liquid_slot, .why = liquid_why },
    .{ .region = "gfx_surfaceBG", .tiles = &.{ 0x59, 0x5A, 0x5B, 0x5E, 0x60, 0x61, 0x62, 0x63 }, .slot = spike_slot, .why = spike_why },
    .{ .region = "gfx_lavaCavesA", .tiles = &.{ 0x3A, 0x3B, 0x3C, 0x3D }, .slot = spike_slot, .why = spike_why },
    .{ .region = "gfx_lavaCavesA", .tiles = &.{ 0x11, 0x12, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x24, 0x25, 0x26, 0x27, 0x2C, 0x2D, 0x2E, 0x2F, 0x31, 0x36, 0x37, 0x38, 0x39, 0x46, 0x48, 0x4A, 0x4F, 0x50, 0x51, 0x52 }, .slot = acid_slot, .why = acid_why },
    .{ .region = "gfx_lavaCavesA", .tiles = &.{ 0x15, 0x16, 0x42, 0x43, 0x44, 0x45 }, .slot = liquid_slot, .why = liquid_why },
    .{ .region = "gfx_lavaCavesB", .tiles = &.{ 0x3A, 0x3B, 0x3C, 0x3D }, .slot = spike_slot, .why = spike_why },
    .{ .region = "gfx_lavaCavesB", .tiles = &.{ 0x11, 0x12, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x24, 0x25, 0x26, 0x27, 0x2C, 0x2D, 0x2E, 0x2F, 0x31, 0x36, 0x37, 0x38, 0x39, 0x46, 0x48, 0x4A, 0x4F, 0x50, 0x51, 0x52 }, .slot = acid_slot, .why = acid_why },
    .{ .region = "gfx_lavaCavesB", .tiles = &.{ 0x15, 0x16, 0x42, 0x43, 0x44, 0x45 }, .slot = liquid_slot, .why = liquid_why },
    .{ .region = "gfx_lavaCavesC", .tiles = &.{ 0x3A, 0x3B, 0x3C, 0x3D }, .slot = spike_slot, .why = spike_why },
    .{ .region = "gfx_lavaCavesC", .tiles = &.{ 0x11, 0x12, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x24, 0x25, 0x26, 0x27, 0x2C, 0x2D, 0x2E, 0x2F, 0x31, 0x36, 0x37, 0x38, 0x39, 0x46, 0x48, 0x4A, 0x4F, 0x50, 0x51, 0x52 }, .slot = acid_slot, .why = acid_why },
    .{ .region = "gfx_lavaCavesC", .tiles = &.{ 0x15, 0x16, 0x42, 0x43, 0x44, 0x45 }, .slot = liquid_slot, .why = liquid_why },
    .{ .region = "gfx_ruinsExt", .tiles = &.{ 0x0C, 0x0D, 0x0E, 0x0F, 0x14, 0x15, 0x27, 0x28, 0x29, 0x2A, 0x38, 0x39 }, .slot = spike_slot, .why = spike_why },
    .{ .region = "gfx_ruinsExt", .tiles = &.{ 0x3A, 0x3B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61, 0x62, 0x63 }, .slot = acid_slot, .why = acid_why },
    .{ .region = "gfx_ruinsExt", .tiles = &.{ 0x54, 0x55, 0x70, 0x71, 0x72, 0x73 }, .slot = liquid_slot, .why = liquid_why },
    .{ .region = "gfx_finalLab", .tiles = &.{ 0x3A, 0x42, 0x43, 0x6B }, .slot = spike_slot, .why = spike_why },
};

const spike_why = "a spike or coral: red in every area";
const acid_why = "acid: purple in every area";
const liquid_why = "the liquid that slows Samus: yellow in every area";
