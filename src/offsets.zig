//! Where everything lives in the retail ROM (Step 2).
//!
//! Every entry records **how we know** its address and size, the way
//! `snes_game_dev`'s `ff6/offsets.zig` does. That discipline is not decoration:
//! a re-derivation can be checked against the cartridge and a transcription
//! cannot, so a note saying only "M2RoS says so" is not enough. (It began
//! because M2RoS then shipped no LICENSE; it is MIT now, credited in
//! THIRD-PARTY-NOTICES, and the reason stands without that.)
//!
//! The strongest notes here are the ones where arithmetic closes on an
//! independently-known address - bank 8's metatile block walking gaplessly from
//! $4880 to gfx_metAlpha at $59BC, or the enemy data pointer table's size
//! falling out of 7 map banks x 256 screens. Those are checkable without
//! trusting anyone's labels.
//!
//! **Not yet verified against the ROM.** Every address here is derived from
//! M2RoS's extraction scripts and source, cross-checked against each other and
//! against the measured facts in `01-requirements.md`. Confirming them against
//! actual bytes needs the ROM, and is what `verifyAgainstRom` below exists for -
//! it runs from `zig build verify` as soon as a ROM is configured.

const std = @import("std");

/// A Game Boy bank is 16 KiB. Bank 0 is fixed at $0000-$3FFF; every other bank
/// is paged into $4000-$7FFF, which is why banked addresses have $4000 set.
pub const bank_size: usize = 0x4000;

pub const Kind = enum {

    collision,
    collision_pointers,
    door_data,
    door_pointers,
    enemy_damage,
    enemy_data,
    enemy_data_pointers,
    enemy_header_pointers,
    enemy_headers,
    enemy_hitbox_pointers,
    enemy_hitboxes,
    graphics_enemy,
    graphics_item,
    graphics_samus,
    graphics_tileset,
    graphics_ui,
    item_names,
    map_screen_pointers,
    map_screens,
    map_scroll_flags,
    map_transition_indexes,
    metasprite_data,
    metasprite_pointers,
    hitbox,
    initial_save,
    metatiles,
    physics,
    pose_sprites,
    pose_transition,
    solidity,
    sound_entry,
    // Bank 4's sound data (metroid2-audio Step 5). Eight kinds rather than one
    // because these are eight genuinely different formats -- a frequency table,
    // a tempo ladder, wave RAM, register runs, effect steps, a pointer table,
    // a flag byte per song, and a pointer-carrying instruction stream -- and
    // the exhaustive switches elsewhere should make each one state its own
    // round-trip claim.
    sound_notes,
    sound_tempo,
    sound_wave_patterns,
    sound_option_sets,
    sound_effect_table,
    sound_song_table,
    sound_flags,
    sound_song_data,
    tilemap,
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// Game Boy bank number.
    bank: u8,
    /// Address as the CPU sees it: $0000-$3FFF in bank 0, $4000-$7FFF banked.
    gb_addr: u16,
    size: usize,
    /// How we know. Never empty - enforced by a test below.
    note: []const u8,

    /// Flat offset into the ROM image.
    pub fn romOffset(self: Entry) usize {
        return @as(usize, self.bank) * bank_size + (self.gb_addr & 0x3FFF);
    }

    pub fn romEnd(self: Entry) usize {
        return self.romOffset() + self.size;
    }
};

pub const entries = [_]Entry{

    .{ .name = "gfx_titleScreen", .kind = .graphics_ui, .bank = 0x5, .gb_addr = 0x5F34, .size = 0xA00, .note = "M2RoS extract_chr.py. Bank 5 title/credits block runs $5F34-$7F34 with no gaps: each entry's address equals the previous address plus its size, and the block ends exactly at doorData's freespace marker (05:7F34 in extract_doors.py)." },
    .{ .name = "gfx_creditsFont", .kind = .graphics_ui, .bank = 0x5, .gb_addr = 0x6934, .size = 0x300, .note = "M2RoS extract_chr.py. Bank 5 title/credits block runs $5F34-$7F34 with no gaps: each entry's address equals the previous address plus its size, and the block ends exactly at doorData's freespace marker (05:7F34 in extract_doors.py)." },
    .{ .name = "gfx_itemFont", .kind = .graphics_ui, .bank = 0x5, .gb_addr = 0x6C34, .size = 0x200, .note = "M2RoS extract_chr.py. Bank 5 title/credits block runs $5F34-$7F34 with no gaps: each entry's address equals the previous address plus its size, and the block ends exactly at doorData's freespace marker (05:7F34 in extract_doors.py)." },
    .{ .name = "gfx_creditsNumbers", .kind = .graphics_ui, .bank = 0x5, .gb_addr = 0x6E34, .size = 0x100, .note = "M2RoS extract_chr.py. Bank 5 title/credits block runs $5F34-$7F34 with no gaps: each entry's address equals the previous address plus its size, and the block ends exactly at doorData's freespace marker (05:7F34 in extract_doors.py)." },
    .{ .name = "gfx_creditsSprTiles", .kind = .graphics_ui, .bank = 0x5, .gb_addr = 0x6F34, .size = 0xF00, .note = "M2RoS extract_chr.py. Bank 5 title/credits block runs $5F34-$7F34 with no gaps: each entry's address equals the previous address plus its size, and the block ends exactly at doorData's freespace marker (05:7F34 in extract_doors.py)." },
    .{ .name = "gfx_theEnd", .kind = .graphics_ui, .bank = 0x5, .gb_addr = 0x7E34, .size = 0x100, .note = "M2RoS extract_chr.py. Bank 5 title/credits block runs $5F34-$7F34 with no gaps: each entry's address equals the previous address plus its size, and the block ends exactly at doorData's freespace marker (05:7F34 in extract_doors.py)." },
    .{ .name = "gfx_cannonBeam", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4000, .size = 0x20, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_cannonMissile", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4020, .size = 0x20, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_beamIce", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4040, .size = 0x20, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_beamWave", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4060, .size = 0x20, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_beamSpazerPlasma", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4080, .size = 0x20, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_spinSpaceTop", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x40A0, .size = 0x70, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_spinSpaceBottom", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4110, .size = 0x50, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_spinScrewTop", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4160, .size = 0x70, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_spinScrewBottom", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x41D0, .size = 0x50, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_spinSpaceScrewTop", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4220, .size = 0x70, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_spinSpaceScrewBottom", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4290, .size = 0x50, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_springBallTop", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x42E0, .size = 0x20, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_springBallBottom", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4300, .size = 0x20, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_samusPowerSuit", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4320, .size = 0xB00, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_samusVariaSuit", .kind = .graphics_samus, .bank = 0x6, .gb_addr = 0x4E20, .size = 0xB00, .note = "M2RoS extract_chr.py. Bank 6 is gapless from $4000 to $7920: every entry begins where the previous one ends, so the whole run is self-checking against its own sizes." },
    .{ .name = "gfx_enemiesA", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x5920, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_enemiesB", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x5D20, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_enemiesC", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x6120, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_enemiesD", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x6520, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_enemiesE", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x6920, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_enemiesF", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x6D20, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_arachnus", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x7120, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_surfaceSPR", .kind = .graphics_enemy, .bank = 0x6, .gb_addr = 0x7520, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_plantBubbles", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x4000, .size = 0x800, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_ruinsInside", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x4800, .size = 0x800, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_queenBG", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x5000, .size = 0x800, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_caveFirst", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x5800, .size = 0x800, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_surfaceBG", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x6000, .size = 0x800, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_lavaCavesA", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x6800, .size = 0x530, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_lavaCavesB", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x6D30, .size = 0x530, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_lavaCavesC", .kind = .graphics_tileset, .bank = 0x7, .gb_addr = 0x7260, .size = 0x530, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_items", .kind = .graphics_item, .bank = 0x7, .gb_addr = 0x7790, .size = 0x2C0, .note = "M2RoS extract_chr.py. Follows lavaCavesC ($7260+$530=$7790) and precedes itemOrb, so bank 7 stays gapless from $4000 to $7B90." },
    .{ .name = "gfx_itemOrb", .kind = .graphics_item, .bank = 0x7, .gb_addr = 0x7A50, .size = 0x40, .note = "M2RoS extract_chr.py; $7790+$2C0=$7A50." },
    .{ .name = "gfx_commonItems", .kind = .graphics_item, .bank = 0x7, .gb_addr = 0x7A90, .size = 0x100, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "title_tilemap", .kind = .tilemap, .bank = 0x5, .gb_addr = 0x5B34, .size = 0x400, .note = "Pinned in Step 7 by the same next-routine arithmetic the other bank-5 offsets use, and pinned at both ends rather than one. Below it, `credits_starPositions` is sixteen (y, x) pairs at 05:5B14, so $5B14+$20 = $5B34 is where the tilemap must begin; above it, `gfx_titleScreen` is already pinned at 05:5F34 by the title/credits block's own gapless arithmetic, so $5F34-$5B34 = $400 is the size. $400 is 32x32, which is the whole of the Game Boy's BG tilemap and the shape a screen-sized map has to be. F2 catalogued this as unknown because `SRC/data/title_tilemap.asm` carries no address of its own; the address is on the *include* line in `SRC/bank_005.asm` instead, which is why a grep of the data file found nothing. The 1024 bytes at ROM offset $15B34 reproduce that file's 32 `db` rows byte for byte." },
    .{ .name = "bg_queenHead", .kind = .tilemap, .bank = 0x8, .gb_addr = 0x4000, .size = 0x80, .note = "M2RoS docs/graphics pointers.txt lists four door-script source pointers at $4000/$4020/$4040/$4060 targeting _SCRN1 rows, i.e. four 32-byte tilemap rows = $80 total." },
    .{ .name = "collision_plantBubbles", .kind = .collision, .bank = 0x8, .gb_addr = 0x4180, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $0 loads this tileset's graphics (5 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_ruinsInside", .kind = .collision, .bank = 0x8, .gb_addr = 0x4280, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $1 loads this tileset's graphics (21 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_queen", .kind = .collision, .bank = 0x8, .gb_addr = 0x4380, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $2 loads this tileset's graphics (5 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_caveFirst", .kind = .collision, .bank = 0x8, .gb_addr = 0x4480, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $3 loads this tileset's graphics (5 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_surface", .kind = .collision, .bank = 0x8, .gb_addr = 0x4580, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $4 loads this tileset's graphics (3 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_lavaCaves", .kind = .collision, .bank = 0x8, .gb_addr = 0x4680, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $5 loads this tileset's graphics (25 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_ruinsExt", .kind = .collision, .bank = 0x8, .gb_addr = 0x4780, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $6 loads this tileset's graphics (27 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_finalLab", .kind = .collision, .bank = 0x8, .gb_addr = 0x4080, .size = 0x100, .note = "Eight $100-byte tables, gapless $4080-$4880, immediately followed by the metatile block. One table per tileset, and $100 entries matches one collision byte per tile id. **The addresses moved on 2026-09-08; see docs/bug_tracker.md.** Until then each name sat one slot below the table it names, because the entries were written out in operand order on the assumption that the block is laid out in that order too. It is not: `finalLab` is physically first, at $4080, and the other seven follow in operand order from $4180 -- so operand $N is at $4080+($N+1)*$100 for $N under 7, and operand $7 is at $4080. The game's own new-game record settles it (`initial_save` names $4580 for the surface, where the old table said $4480), M2RoS's bank_008.asm lists the includes in that physical order, and the water bug below reads correctly for the first time under these names. The correction is names only: `tileset.collisionOrder` resolves an operand through the ROM's pointer table by address, so every cart built before and after this change is byte-identical. Which operand names which tileset is derived from the ROM, not from layout: every door script that issues COLLISION $7 loads this tileset's graphics (4 scripts do, and no operand ever pairs with two tilesets). SOLIDITY uses the same index. The solidity rows agree, but only as a hint: a threshold is compared against an 8x8 tile id, not a metatile index -- samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity -- and row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128. Row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit and this cannot settle the order on its own. The door scripts do." },
    .{ .name = "collision_pointers", .kind = .collision_pointers, .bank = 0x8, .gb_addr = 0x7EEA, .size = 0x10, .note = "The collision op does not index the eight tables by address arithmetic; it indexes this pointer table. Disassembled from the op's own handler at 00:$2859: `AND $0F` takes the operand, `SLA A` doubles it, and `LD HL,$7EEA / ADD HL,DE` reads the entry, with bank 8 already selected by the `LD ($2100),A` two instructions earlier. The mapping it holds is not the identity -- operand $6 selects $4780, the eighth table -- which is why it has to be read rather than assumed. Exactly eight entries: $7EEA+$10 is $7EFA, where `solidity_thresholds` begins, so an operand above $7 would read a threshold row as a pointer. The handler masks with $0F and does not range-check, but no door script uses one." },
    .{ .name = "metatiles_plantBubbles", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x4880, .size = 0x200, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM." },
    .{ .name = "metatiles_ruinsInside", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x4A80, .size = 0x200, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM." },
    .{ .name = "metatiles_finalLab", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x4C80, .size = 0x200, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM." },
    .{ .name = "metatiles_queen", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x4E80, .size = 0x200, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM." },
    .{ .name = "metatiles_caveFirst", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x5080, .size = 0x200, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM." },
    .{ .name = "metatiles_surface", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x5280, .size = 0x200, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM." },
    .{ .name = "metatiles_lavaCavesMid", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x5480, .size = 0x114, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM. The names are M2RoS's, in layout order Mid/Empty/Full. **Layout order is not operand order**: `metatile_pointers` sends TILETABLE 6 to Empty, 7 to Full and 8 to Mid, and until 2026-09-24 `screens.tiletable_order` used layout order and drew every lava room one acid level high. The names themselves agree with the Game Boy's screen: operand 8, the no-kill table, shows a low acid line, and operand 6, after the first kill, shows none." },
    .{ .name = "metatiles_lavaCavesEmpty", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x5594, .size = 0x114, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM. The names are M2RoS's, in layout order Mid/Empty/Full. **Layout order is not operand order**: `metatile_pointers` sends TILETABLE 6 to Empty, 7 to Full and 8 to Mid, and until 2026-09-24 `screens.tiletable_order` used layout order and drew every lava room one acid level high. The names themselves agree with the Game Boy's screen: operand 8, the no-kill table, shows a low acid line, and operand 6, after the first kill, shows none." },
    .{ .name = "metatiles_lavaCavesFull", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x56A8, .size = 0x114, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM. The names are M2RoS's, in layout order Mid/Empty/Full. **Layout order is not operand order**: `metatile_pointers` sends TILETABLE 6 to Empty, 7 to Full and 8 to Mid, and until 2026-09-24 `screens.tiletable_order` used layout order and drew every lava room one acid level high. The names themselves agree with the Game Boy's screen: operand 8, the no-kill table, shows a low acid line, and operand 6, after the first kill, shows none." },
    .{ .name = "metatiles_ruinsExt", .kind = .metatiles, .bank = 0x8, .gb_addr = 0x57BC, .size = 0x200, .note = "M2RoS extract_tileset.py. The whole metatile block is gapless from $4880 to $59BC, where gfx_metAlpha begins - each entry's address is exactly the previous address plus its size, including the three $114-byte lavaCaves variants among seven $200-byte tables. That arithmetic closing on an independently-known address is the strongest evidence available without the ROM." },
    .{ .name = "gfx_metAlpha", .kind = .graphics_enemy, .bank = 0x8, .gb_addr = 0x59BC, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_metGamma", .kind = .graphics_enemy, .bank = 0x8, .gb_addr = 0x5DBC, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_metZeta", .kind = .graphics_enemy, .bank = 0x8, .gb_addr = 0x61BC, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_metOmega", .kind = .graphics_enemy, .bank = 0x8, .gb_addr = 0x65BC, .size = 0x400, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_ruinsExt", .kind = .graphics_tileset, .bank = 0x8, .gb_addr = 0x69BC, .size = 0x800, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_finalLab", .kind = .graphics_tileset, .bank = 0x8, .gb_addr = 0x71BC, .size = 0x800, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address." },
    .{ .name = "gfx_queenSPR", .kind = .graphics_enemy, .bank = 0x8, .gb_addr = 0x79BC, .size = 0x500, .note = "bank 6/7/8 graphics addresses cross-checked three ways: M2RoS's extract_chr.py table, its docs/graphics pointers.txt (which lists the same values as raw ROM offsets), and the door-script source-pointer table in extract_doors.py, which the running game actually dereferences. Three independent expressions of the same address. Size $500 = 16x5 tiles per docs/graphics pointers.txt." },
    .{ .name = "metatile_pointers", .kind = .physics, .bank = 0x8, .gb_addr = 0x7F1A, .size = 0x14, .note = "Pinned in Step 15a, from the handler that reads it: `door_loadTiletable` (00:$282A) banks in 8 and does `LD HL,$7F1A / ADD HL,DE` on the operand doubled, then stores the two bytes it reads in the save buffer at $D80D/$D80E before copying the table. Ten entries because there are ten metatile tables, and all ten name an `offsets.zig` metatile entry's own address ($4C80 finalLab ... $57BC ruinsExt); the table ends at $7F2E, where the bank's freespace zeros begin, and it begins exactly where `solidity_thresholds` ends. The cart carries it because a save record holds the pointer and not the operand." },
    .{ .name = "solidity_thresholds", .kind = .solidity, .bank = 0x8, .gb_addr = 0x7EFA, .size = 0x20, .note = "M2RoS SRC/tilesets/solidityValues.asm carries the address 8:7EFA in its header comment. Eight rows of four bytes, one row per tileset, each ending $FF - so $20 bytes total. A SOLIDITY operand indexes these rows, and it is the same tileset index COLLISION uses: row 0 plantBubbles, 1 ruinsInside, 2 queen, 3 caveFirst, 4 surface, 5 lavaCaves, 6 ruinsExt, 7 finalLab. A threshold is compared against an 8x8 tile id rather than a metatile index: samus_getTileIndex 00:1FF5 reaches the tilemap through getTilemapAddress 00:22BC, which indexes $9800 at 8-pixel granularity. Row 5's 66 is the only row low enough to be about lavaCaves, whose graphics stop at 83 tiles where every other tileset has 128 - a check on the order that owes nothing to the door scripts, though not a decisive one: row 2 thresholds at $F0, past the end of any tileset, so a row is not obliged to fit inside the one it belongs to." },
    .{ .name = "map9_screen_pointers", .kind = .map_screen_pointers, .bank = 0x9, .gb_addr = 0x4000, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. $200 = 256 words, one per cell of the 16x16 screen grid." },
    .{ .name = "map9_scroll_flags", .kind = .map_scroll_flags, .bank = 0x9, .gb_addr = 0x4200, .size = 0x100, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 01-requirements.md independently records map_scrollData at bank offset $4200 indexed screenY*16+screenX, which is exactly this region's address and size." },
    .{ .name = "map9_transition_indexes", .kind = .map_transition_indexes, .bank = 0x9, .gb_addr = 0x4300, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A." },
    .{ .name = "map9_screens", .kind = .map_screens, .bank = 0x9, .gb_addr = 0x4500, .size = 0x3B00, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 59 screens x $100 bytes = $3B00, filling the bank exactly." },
    .{ .name = "mapA_screen_pointers", .kind = .map_screen_pointers, .bank = 0xA, .gb_addr = 0x4000, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. $200 = 256 words, one per cell of the 16x16 screen grid." },
    .{ .name = "mapA_scroll_flags", .kind = .map_scroll_flags, .bank = 0xA, .gb_addr = 0x4200, .size = 0x100, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 01-requirements.md independently records map_scrollData at bank offset $4200 indexed screenY*16+screenX, which is exactly this region's address and size." },
    .{ .name = "mapA_transition_indexes", .kind = .map_transition_indexes, .bank = 0xA, .gb_addr = 0x4300, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A." },
    .{ .name = "mapA_screens", .kind = .map_screens, .bank = 0xA, .gb_addr = 0x4500, .size = 0x3B00, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 59 screens x $100 bytes = $3B00, filling the bank exactly." },
    .{ .name = "mapB_screen_pointers", .kind = .map_screen_pointers, .bank = 0xB, .gb_addr = 0x4000, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. $200 = 256 words, one per cell of the 16x16 screen grid." },
    .{ .name = "mapB_scroll_flags", .kind = .map_scroll_flags, .bank = 0xB, .gb_addr = 0x4200, .size = 0x100, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 01-requirements.md independently records map_scrollData at bank offset $4200 indexed screenY*16+screenX, which is exactly this region's address and size." },
    .{ .name = "mapB_transition_indexes", .kind = .map_transition_indexes, .bank = 0xB, .gb_addr = 0x4300, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A." },
    .{ .name = "mapB_screens", .kind = .map_screens, .bank = 0xB, .gb_addr = 0x4500, .size = 0x3B00, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 59 screens x $100 bytes = $3B00, filling the bank exactly." },
    .{ .name = "mapC_screen_pointers", .kind = .map_screen_pointers, .bank = 0xC, .gb_addr = 0x4000, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. $200 = 256 words, one per cell of the 16x16 screen grid." },
    .{ .name = "mapC_scroll_flags", .kind = .map_scroll_flags, .bank = 0xC, .gb_addr = 0x4200, .size = 0x100, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 01-requirements.md independently records map_scrollData at bank offset $4200 indexed screenY*16+screenX, which is exactly this region's address and size." },
    .{ .name = "mapC_transition_indexes", .kind = .map_transition_indexes, .bank = 0xC, .gb_addr = 0x4300, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A." },
    .{ .name = "mapC_screens", .kind = .map_screens, .bank = 0xC, .gb_addr = 0x4500, .size = 0x3B00, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 59 screens x $100 bytes = $3B00, filling the bank exactly." },
    .{ .name = "mapD_screen_pointers", .kind = .map_screen_pointers, .bank = 0xD, .gb_addr = 0x4000, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. $200 = 256 words, one per cell of the 16x16 screen grid." },
    .{ .name = "mapD_scroll_flags", .kind = .map_scroll_flags, .bank = 0xD, .gb_addr = 0x4200, .size = 0x100, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 01-requirements.md independently records map_scrollData at bank offset $4200 indexed screenY*16+screenX, which is exactly this region's address and size." },
    .{ .name = "mapD_transition_indexes", .kind = .map_transition_indexes, .bank = 0xD, .gb_addr = 0x4300, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A." },
    .{ .name = "mapD_screens", .kind = .map_screens, .bank = 0xD, .gb_addr = 0x4500, .size = 0x3B00, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 59 screens x $100 bytes = $3B00, filling the bank exactly." },
    .{ .name = "mapE_screen_pointers", .kind = .map_screen_pointers, .bank = 0xE, .gb_addr = 0x4000, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. $200 = 256 words, one per cell of the 16x16 screen grid." },
    .{ .name = "mapE_scroll_flags", .kind = .map_scroll_flags, .bank = 0xE, .gb_addr = 0x4200, .size = 0x100, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 01-requirements.md independently records map_scrollData at bank offset $4200 indexed screenY*16+screenX, which is exactly this region's address and size." },
    .{ .name = "mapE_transition_indexes", .kind = .map_transition_indexes, .bank = 0xE, .gb_addr = 0x4300, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A." },
    .{ .name = "mapE_screens", .kind = .map_screens, .bank = 0xE, .gb_addr = 0x4500, .size = 0x3B00, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 59 screens x $100 bytes = $3B00, filling the bank exactly." },
    .{ .name = "mapF_screen_pointers", .kind = .map_screen_pointers, .bank = 0xF, .gb_addr = 0x4000, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. $200 = 256 words, one per cell of the 16x16 screen grid." },
    .{ .name = "mapF_scroll_flags", .kind = .map_scroll_flags, .bank = 0xF, .gb_addr = 0x4200, .size = 0x100, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 01-requirements.md independently records map_scrollData at bank offset $4200 indexed screenY*16+screenX, which is exactly this region's address and size." },
    .{ .name = "mapF_transition_indexes", .kind = .map_transition_indexes, .bank = 0xF, .gb_addr = 0x4300, .size = 0x200, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A." },
    .{ .name = "mapF_screens", .kind = .map_screens, .bank = 0xF, .gb_addr = 0x4500, .size = 0x3B00, .note = "M2RoS extract_maps.py partitions every map bank identically. The partition is self-checking: screen bodies start at $4500 and run to $8000 in $100-byte steps, giving exactly (0x4000-0x500)/0x100 = 59 screens, which matches the '59 unique screens' figure in docs/ROM Tour.md derived independently. Step 4 confirmed this from the ROM: the seven banks reference exactly 413 distinct screen bodies (7 x 59). It also pinned down what an in-use cell is - one whose pointer is not the shared blank at $4500 - which yields exactly the 905 in-use screens the requirements record. 904 resolve to an aligned body; the one that does not is a null $0000 in bank $A. 59 screens x $100 bytes = $3B00, filling the bank exactly." },
    .{ .name = "enemy_data_pointers", .kind = .enemy_data_pointers, .bank = 0x3, .gb_addr = 0x42E0, .size = 0xE00, .note = "M2RoS extract_enemyData.py reads pointers from 03:42E0 until enemy data at 03:50E0. The span is $E00 = 1792 words = 7 map banks x 256 screens, which is exactly one enemy-list pointer per screen across banks $9-$F. That the size falls out of the map geometry is the check." },
    .{ .name = "enemy_data", .kind = .enemy_data, .bank = 0x3, .gb_addr = 0x50E0, .size = 0x1164, .note = "M2RoS extract_enemyData.py: data runs 03:50E0 to 03:6244. Records are 4 bytes (spawn number, sprite type, X, Y) terminated by $FF." },
    .{ .name = "enemy_header_pointers", .kind = .enemy_header_pointers, .bank = 0x3, .gb_addr = 0x6300, .size = 0x1FE, .note = "M2RoS extract_enHeaders.py: 255 pointers from 03:6300, so $1FE bytes, ending at $64FE where the headers themselves begin. 255 = the enemy id space." },
    .{ .name = "enemy_headers", .kind = .enemy_headers, .bank = 0x3, .gb_addr = 0x64FE, .size = 0x23C, .note = "M2RoS extract_enHeaders.py: 03:64FE to 03:673A. Ends exactly where the damage table's address (03:673A, from bank_003.asm's enemyDamageTable label) begins. Step 4 derived the 11-byte record stride independently of that source: $23C divides evenly by 4, 11, 13, 26, 44, 52 and 143, but 11 is the only stride above 1 that all 51 distinct in-region header pointers are a multiple of. Framing only - the 9 bytes and trailing word are not yet interpreted." },
    .{ .name = "enemy_damage", .kind = .enemy_damage, .bank = 0x3, .gb_addr = 0x673A, .size = 0xFF, .note = "bank_003.asm labels enemyDamageTable at 03:673A. It runs to the hitbox pointer table at 03:6839 (extract_enHitboxes.py), giving $FF bytes = one damage byte per enemy id, which agrees with the 255-entry header pointer table." },
    .{ .name = "enemy_hitbox_pointers", .kind = .enemy_hitbox_pointers, .bank = 0x3, .gb_addr = 0x6839, .size = 0x1FE, .note = "M2RoS extract_enHitboxes.py: 255 pointers from 03:6839, $1FE bytes, ending at $6A37 where the hitboxes begin. Same 255-entry shape as the header pointers." },
    .{ .name = "enemy_hitboxes", .kind = .enemy_hitboxes, .bank = 0x3, .gb_addr = 0x6A37, .size = 0xB0, .note = "M2RoS extract_enHitboxes.py: 03:6A37 to 03:6AE7. Records are 4 signed bytes. Step 4 checked that stride against the hitbox pointer table: 1, 2 and 4 all survive, so 4 is the largest consistent stride rather than a forced one - weaker evidence than the header case, deliberately recorded as such. 41 of the 44 records are referenced, and one pointer sits at $C360, a WRAM address and so a dead slot." },
    .{ .name = "door_pointers", .kind = .door_pointers, .bank = 0x5, .gb_addr = 0x42E5, .size = 0x400, .note = "M2RoS extract_doors.py reads pointers from 05:42E5 until door data at 05:46E5 - $400 bytes = 512 door entries. bank_005.asm independently labels doorPointerTable with the comment '; 05:42E5'. All 512 are accounted for against the decoded stream: 497 land on an operation boundary, 14 target $55A3 (one past the last operation, i.e. empty scripts) and 1 targets bank 5 freespace at $7F34." },
    .{ .name = "door_data", .kind = .door_data, .bank = 0x5, .gb_addr = 0x46E5, .size = 0xEBE, .note = "M2RoS extract_doors.py: 05:46E5 to 05:55A3. bank_005.asm places doorData_end after the included doors.asm. Step 4's decoder re-encodes all 1872 operations in this region to the same bytes, which is the strongest evidence available that the opcode and operand-length table is right: a misread length desynchronises the stream and the round-trip would not close. It also yields 171 IF_MET_LESS transitions across 13 distinct thresholds, matching a figure derived independently from the other disassembly." },
    .{ .name = "metasprite_samus_pointers", .kind = .metasprite_pointers, .bank = 0x1, .gb_addr = 0x4000, .size = 0x8A, .note = "M2RoS extract_metasprites.py, spriteSet 1. Pointer table runs from the set's start to its data start; entries are 4-byte (y, x, tile, attr) rows terminated by $FF. Step 4 walked the data linearly and matched pointers against record starts: across all three sets 361 of 362 pointers land on a record, and the one that does not is $C300, a WRAM address and so a dead slot." },
    .{ .name = "metasprite_samus_data", .kind = .metasprite_data, .bank = 0x1, .gb_addr = 0x408A, .size = 0x8B4, .note = "M2RoS extract_metasprites.py, spriteSet 1. Pointer table runs from the set's start to its data start; entries are 4-byte (y, x, tile, attr) rows terminated by $FF. Step 4 walked the data linearly and matched pointers against record starts: across all three sets 361 of 362 pointers land on a record, and the one that does not is $C300, a WRAM address and so a dead slot." },
    .{ .name = "metasprite_enemies_pointers", .kind = .metasprite_pointers, .bank = 0x1, .gb_addr = 0x5AB1, .size = 0x1FE, .note = "M2RoS extract_metasprites.py, spriteSet 2. Pointer table runs from the set's start to its data start; entries are 4-byte (y, x, tile, attr) rows terminated by $FF. Step 4 walked the data linearly and matched pointers against record starts: across all three sets 361 of 362 pointers land on a record, and the one that does not is $C300, a WRAM address and so a dead slot." },
    .{ .name = "metasprite_enemies_data", .kind = .metasprite_data, .bank = 0x1, .gb_addr = 0x5CAF, .size = 0x140B, .note = "M2RoS extract_metasprites.py, spriteSet 2. Pointer table runs from the set's start to its data start; entries are 4-byte (y, x, tile, attr) rows terminated by $FF. Step 4 walked the data linearly and matched pointers against record starts: across all three sets 361 of 362 pointers land on a record, and the one that does not is $C300, a WRAM address and so a dead slot." },
    .{ .name = "metasprite_credits_pointers", .kind = .metasprite_pointers, .bank = 0x1, .gb_addr = 0x744A, .size = 0x4C, .note = "M2RoS extract_metasprites.py, spriteSet 3. Pointer table runs from the set's start to its data start; entries are 4-byte (y, x, tile, attr) rows terminated by $FF. Step 4 walked the data linearly and matched pointers against record starts: across all three sets 361 of 362 pointers land on a record, and the one that does not is $C300, a WRAM address and so a dead slot." },
    .{ .name = "metasprite_credits_data", .kind = .metasprite_data, .bank = 0x1, .gb_addr = 0x7496, .size = 0x559, .note = "M2RoS extract_metasprites.py, spriteSet 3. Pointer table runs from the set's start to its data start; entries are 4-byte (y, x, tile, attr) rows terminated by $FF. Step 4 walked the data linearly and matched pointers against record starts: across all three sets 361 of 362 pointers land on a record, and the one that does not is $C300, a WRAM address and so a dead slot." },
    .{ .name = "pose_sprites_knockback", .kind = .pose_sprites, .bank = 0x1, .gb_addr = 0x4C69, .size = 0x02, .note = "Pinned in Step 11, closing the `samus_pose_tables` pending entry. `drawSamus_knockback` (01:4C59) serves poses $0F and $11 and indexes this by the facing byte alone, so it is two entries and can be no other length. Both ends from the ROM: the near end is `21 69 4C` -- `ld hl,$4C69` -- which occurs exactly once in bank 1, and $4C69 + $02 = 01:4C6B, where `FA 2B D0` (`ld a,[samusFacingDirection]`) begins drawSamus_spider. The bytes are `16 09`, left then right -- and those are the same two ids `pose_sprites_jump` holds at its right and left slots, which is the cross-check that makes this a knockback *pose* table rather than two arbitrary bytes: knockback reuses the jump sprite. Bank 1 is banked, so the ROM offset is $4C69." },
    .{ .name = "pose_sprites_spider", .kind = .pose_sprites, .bank = 0x1, .gb_addr = 0x4C8C, .size = 0x08, .note = "Pinned in Step 11. `drawSamus_spider` (01:4C6B) serves poses $0B-$0E and indexes this with (facing & 1) * 4 + (samus_spinAnimationTimer & $0C) >> 2, which is two four-frame rows and fixes the width at eight. Near end `21 8C 4C`, once in bank 1; far end $4C8C + $08 = 01:4C94, where `FA 2B D0` begins drawSamus_morph. The bytes are `37 38 39 3A 3B 3C 3D 3E`: two consecutive runs of four, which is the shape a pair of animation tables has and is not a shape SM83 code takes. Bank 1 is banked, so the ROM offset is $4C8C." },
    .{ .name = "pose_sprites_morph", .kind = .pose_sprites, .bank = 0x1, .gb_addr = 0x4CB5, .size = 0x08, .note = "Pinned in Step 11, and it is the table the Queen sequence uses too. `drawSamus_morph` (01:4C94) indexes it exactly as drawSamus_spider indexes its own, and `samus_drawJumpTable` sends poses $05, $06, $08, $10, $12 *and all six Queen poses $18-$1D* here -- so there is no separate queen table to find, which is what closes `samus_pose_tables` rather than shrinking it. Near end `21 B5 4C`, once in bank 1; far end $4CB5 + $08 = 01:4CBD, where `16 00` (`ld d,$00`) begins drawSamus_jump, whose address `pose_sprites_jump`'s note already pinned independently. The bytes are `1E 1F 20 21 26 27 28 29`. Bank 1 is banked, so the ROM offset is $4CB5." },
    .{ .name = "pose_sprites_jump", .kind = .pose_sprites, .bank = 0x1, .gb_addr = 0x4CDE, .size = 0x10, .note = "Pinned in Step 13a. The six draw routines Phase 0a reaches are code, not a table - `drawSamus` (01:4BD9) dispatches through samus_drawJumpTable, which holds *code* pointers - but four of them index a little `db SPRITE_SAMUS_*` table of their own, and those are ROM bytes. Every one's far end is fixed by the address of the next routine rather than by a listing, and that routine is identified by its own first instruction rather than by a label: `drawSamus_jump` (01:4CBD, shared by the jumping and falling poses) indexes this with the nibble-swapped facing/d-pad byte `drawSamus` builds, so the sixteen entries are (no vertical, up, down, both) x (none, right, left, both). $4CDE + $10 lands exactly on 01:4CEE, where `FA 2B D0` - `ld a, [samusFacingDirection]` - begins drawSamus_spinJump. The bytes are `00 09 16 00 00 0A 17 00 00 0C 19 00 00 00 00 00`, matching M2RoS entry for entry; the eight zeroes are the facing combinations the dispatch cannot produce. Bank 1 is banked, so the ROM offset is $4CDE." },
    .{ .name = "pose_sprites_spin", .kind = .pose_sprites, .bank = 0x1, .gb_addr = 0x4D2B, .size = 0x08, .note = "Pinned in Step 13a. The six draw routines Phase 0a reaches are code, not a table - `drawSamus` (01:4BD9) dispatches through samus_drawJumpTable, which holds *code* pointers - but four of them index a little `db SPRITE_SAMUS_*` table of their own, and those are ROM bytes. Every one's far end is fixed by the address of the next routine rather than by a listing, and that routine is identified by its own first instruction rather than by a label: `drawSamus_spinJump` (01:4CEE) picks one of two four-frame tables by facing - right at $4D2B, left at $4D2F - and indexes it from samus_spinAnimationTimer, at one of two rates depending on space jump and screw attack. $4D2B + $08 lands exactly on 01:4D33, where `FA 66 D0` begins drawSamus_faceScreen. The bytes are `1A 1B 1C 1D 22 23 24 25`: two consecutive runs of four, which is the shape a pair of animation tables has and is not a shape SM83 code takes. Bank 1 is banked, so the ROM offset is $4D2B." },
    .{ .name = "pose_sprites_standing", .kind = .pose_sprites, .bank = 0x1, .gb_addr = 0x4D54, .size = 0x10, .note = "Pinned in Step 13a. The six draw routines Phase 0a reaches are code, not a table - `drawSamus` (01:4BD9) dispatches through samus_drawJumpTable, which holds *code* pointers - but four of them index a little `db SPRITE_SAMUS_*` table of their own, and those are ROM bytes. Every one's far end is fixed by the address of the next routine rather than by a listing, and that routine is identified by its own first instruction rather than by a label: `drawSamus_standing` indexes this exactly as drawSamus_jump indexes its own, in the same sixteen-entry shape. $4D54 + $10 lands on 01:4D64, one unused pad byte before drawSamus_crouch at 01:4D65 - whose first two bytes are `3E 0B`, `ld a, $0B`, which is `ld a, SPRITE_SAMUS_CROUCH_RIGHT` and so identifies the routine from the ROM alone. The bytes are `00 01 0E 00 00 02 0F 00 00 01 0E 00 00 00 00 00`; aiming down reuses the plain standing sprite, which is why rows 0 and 2 are equal. Bank 1 is banked, so the ROM offset is $4D54." },
    .{ .name = "pose_sprites_running", .kind = .pose_sprites, .bank = 0x1, .gb_addr = 0x4DC7, .size = 0x18, .note = "Pinned in Step 13a. The six draw routines Phase 0a reaches are code, not a table - `drawSamus` (01:4BD9) dispatches through samus_drawJumpTable, which holds *code* pointers - but four of them index a little `db SPRITE_SAMUS_*` table of their own, and those are ROM bytes. Every one's far end is fixed by the address of the next routine rather than by a listing, and that routine is identified by its own first instruction rather than by a label: Three eight-byte tables back to back - normal at $4DC7, firing forwards at $4DCF, aiming up at $4DD7 - each holding left frames 1-3, a pad byte, then right frames 1-3 and a pad. `drawSamus_run` (01:4D77) picks the table from the held input and the row from `samus_animationTimer & $30`, which is what makes the fourth entry padding rather than a frame. $4DC7 + $18 lands exactly on 01:4DDF, where `CD D5 3E` - `call loadScreenSpritePriorityBit` - begins drawSamus_common. The bytes are `10 11 12 00 03 04 05 00 13 14 15 00 06 07 08 00 2E 2F 30 00 2B 2C 2D 00`. Bank 1 is banked, so the ROM offset is $4DC7." },
    .{ .name = "physics_fallArc", .kind = .physics, .bank = 0x0, .gb_addr = 0x1386, .size = 0x17, .note = "Read as an array of per-frame vertical speeds by samus_moveVertical and the jump pose handlers, indexed by samus_fallArcCounter / samus_jumpArcCounter. Located via M2RoS bank_000.asm, which labels the address in a comment on the line; the bytes at that offset in the retail ROM match its listing exactly, and the two velocity tables terminate in $80 where the disassembly says they do. Bank 0 is fixed, so the address is the offset. Not $80-terminated: samus_fallArcCounter is capped at $16 by the code instead." },
    .{ .name = "physics_jumpArc", .kind = .physics, .bank = 0x0, .gb_addr = 0x184A, .size = 0x4F, .note = "Read as an array of per-frame vertical speeds by samus_moveVertical and the jump pose handlers, indexed by samus_fallArcCounter / samus_jumpArcCounter. Located via M2RoS bank_000.asm, which labels the address in a comment on the line; the bytes at that offset in the retail ROM match its listing exactly, and the two velocity tables terminate in $80 where the disassembly says they do. Bank 0 is fixed, so the address is the offset. Entries below samus_jumpArrayBaseOffset ($40) are not read from here - the ascent is linear at 2px/frame (3 with hi-jump) - so the table describes the arc from its apex onwards." },
    .{ .name = "physics_spaceJumpArc", .kind = .physics, .bank = 0x0, .gb_addr = 0x1899, .size = 0x4F, .note = "Read as an array of per-frame vertical speeds by samus_moveVertical and the jump pose handlers, indexed by samus_fallArcCounter / samus_jumpArcCounter. Located via M2RoS bank_000.asm, which labels the address in a comment on the line; the bytes at that offset in the retail ROM match its listing exactly, and the two velocity tables terminate in $80 where the disassembly says they do. Bank 0 is fixed, so the address is the offset. Same shape as the jump arc and read the same way; a zero means space jump is not available on that frame." },
    .{ .name = "collision_samusBGHitboxTop", .kind = .hitbox, .bank = 0x0, .gb_addr = 0x20E9, .size = 0x16, .note = "One byte per pose: the vertical offset of the top of Samus's hitbox, biased by OAM_Y_OFS the way `getTilemapAddress` expects, read by `collision_samusTop` as `table[samusPose]`. Located via M2RoS bank_000.asm ($20E9); the retail bytes match its generated listing entry for entry, and the size is fixed at the far end by the next table starting at $20FF. 22 entries covers poses $00-$15, which is every pose that has a BG hitbox - the queen poses above it reuse the morph row through the y-offset lists instead." },
    .{ .name = "physics_bombArc", .kind = .physics, .bank = 0x0, .gb_addr = 0x0FF6, .size = 0x33, .note = "The knockback arc: `poseFunc_bombed` (00:0F6C) indexes it with `samus_jumpArcCounter - samus_jumpArrayBaseOffset` and enters the falling pose on the $80, exactly as the jump arc is read - so it is the same kind as the other three and parses as one. Both ends come from the ROM rather than from a listing. The near end is `21 F6 0F` at 00:0F74, the only one in bank 0; the far end is $0FF6 + $33 = 00:1029, where `F0 81` -- `ldh a, [hInputRisingEdge]` -- begins `poseFunc_spiderBall`, and the $80 lands on the last byte of that span, which no other length would give. Bank 0 is fixed, so the address is the offset. 51 bytes is 50 frames of arc plus the $80: 23 rising, 4 at zero and 23 falling, which is the symmetry a knockback has and a walk speed does not." },
    .{ .name = "samus_bombedFallingPoses", .kind = .pose_transition, .bank = 0x0, .gb_addr = 0x0FD8, .size = 0x1E, .note = "One pose per pose: what `poseFunc_bombed` puts Samus into when the knockback arc runs out, indexed by the pose she is *in*. 30 entries, poses $00-$1D, which is the same width `samus_damagePoseTable` has and the same width the Queen poses push the id space to. The near end is `21 D8 0F` at 00:0FCF, the routine's own table load and the only one in bank 0; the far end is where `physics_bombArc` begins, which is pinned independently. The bytes are $00 for the first fifteen poses - none of which `poseFunc_bombed` can be entered from - then $07 $08 $07 $08 for the four that can, standing and ball alternating; the Queen poses at the top map to themselves. That alternation is the shape a per-pose transition table has and is not a shape SM83 code takes." },
    .{ .name = "samus_damagePoseTable", .kind = .pose_transition, .bank = 0x0, .gb_addr = 0x208B, .size = 0x1E, .note = "One pose per pose: what `hurtSamus` (00:2EE3) forces Samus into when an enemy touches her, indexed by the pose she is in with bit 7 cleared. The near end is that routine's `21 8B 20` -- `ld hl,$208B` -- which occurs exactly once in bank 0; the far end is 00:20A9, where `spiderDirectionTable`'s four 16-byte rows begin - and those rows are identifiable from the ROM alone, because their 64 bytes are drawn from {$00,$01,$02,$04,$08} and every one begins and ends with $00. 30 entries, and their contents are evidence for the width: every one of poses $00-$13 maps to $0F or $10 - the two knockback poses, standing and ball, picked to match the pose it came from - the four unused poses $14-$17 read $00, and $1A-$1D map to themselves, which is what a table indexed by pose looks like and what an arbitrary 30 bytes does not." },
    .{ .name = "collision_samusHorizontalYOffsets", .kind = .hitbox, .bank = 0x0, .gb_addr = 0x20FF, .size = 0xF0, .note = "Thirty 8-byte rows, one per pose $00-$1D, each an $80-terminated list of vertical offsets at which `collision_samusHorizontal` samples the tilemap. Located via M2RoS bank_000.asm ($20FF); the retail bytes match its generated listing row for row, and the size is pinned from the ROM itself rather than from the listing - $20FF + $F0 lands exactly on $21EF, where `26 DD 2E 00 3E FF` begins the routine that fills the projectile array with $FF. The stride is 8 but the reader is unrolled five deep, so a row can carry at most five offsets; the four unused poses carry a row of zeroes and no terminator at all." },
    .{ .name = "collision_samusSpriteHitboxTop", .kind = .hitbox, .bank = 0x0, .gb_addr = 0x369B, .size = 0x15, .note = "One byte per pose: the top of Samus's hitbox for *sprite* collisions, read by `collision_samusOneEnemy` as `table[samusPose & $7F]`. Not the same table as `collision_samusBGHitboxTop` and not the same length - 21 entries against 22 - because the two are biased differently: this one is `OAM_Y_OFS + toStand - toBottom` and the BG one is not relative to the bottom at all. Two readers name the near end -- `21 9B 36` at 00:33A9 and 00:350D, `collision_samusOneEnemy` and its vertical twin, and nowhere else in bank 0 -- and the far end is fixed by the ROM rather than by the listing, since $369B + $15 lands exactly on 00:36B0, where `CD` -- the `call handleAudio_longJump` that opens `gameMode_dead` -- begins. Bank 0 is fixed, so the address is the offset." },
    .{ .name = "hudBaseTilemap", .kind = .physics, .bank = 0x5, .gb_addr = 0x40F0, .size = 0x14, .note = "Pinned in Step 13b: the status bar's twenty window tile ids, which `loadTitleScreen` copies to `vramDest_statusBar` ($9C00) before anything draws a digit. Both ends from the ROM. The near end is `21 F0 40` at 05:4092, followed by `11 00 9C` and the `06 14` whose $14 the copy loop counts down -- so the length is an operand, not an inference. The far end is $40F0 + $14 = 05:4104, the source of the *next* copy, `21 04 41` at 05:40A0 into $9C20, the window's second row. The same address reaches the Queen room's two redraws at 00:$2491 and $24E6, split across two `LD A,d8`. The bytes are blanks $AF, the dash $9E and the missile icon $9F, and two $FF under the Metroid icon; the digits are not here, because the status bar writes them every vblank. Bank 5 is banked, so the ROM offset is $140F0." },
    .{ .name = "saveTextTilemap", .kind = .physics, .bank = 0x5, .gb_addr = 0x4104, .size = 0x14, .note = "Pinned in Step 24g, from the copy that reads it: `loadTitleScreen`'s second loop, `21 04 41 / 11 20 9C / 06 14` at 05:$40A0, twenty bytes into `vramDest_itemText` ($9C20), the window's second row. Nothing else in the game writes it; the row changes after that only when a door's `ITEM` copies `item_names[op & $0F]` over its first sixteen bytes (00:$26A0), and a save room's `ITEM $D0` puts \" SAVE<>\" back. Measured on the recording: ten writes to $9C20-$9C2F in frames 22 000-50 110, all whole rows, from 00:$2BC4 (the transfer) and 05:$40AA. $FF, then `SAVE` as $D2 $C0 $D5 $C4 in the item font, the two dots $DE $DF, and $FF to column 19." },
    .{ .name = "alpha_angleTable", .kind = .physics, .bank = 0x1, .gb_addr = 0x7158, .size = 0x18, .note = "Pinned in Step 13c: `alpha_getAngleFromTable`'s `.angleTable`, the lunge direction the Alpha picks per quadrant and slope band. Both ends from the ROM. The near end is `21 58 71` at 01:7131, the only one in bank 1, and its reader adds `metroid_angleTableIndex` to it. The far end is $7158 + $18 = 01:7170, `metroid_getSlopeToSamus`, whose first instruction `06 64` -- `LD B,$64`, the slope's multiplier -- is the next routine's and not a table byte. The width is four cardinal entries and four rows of five, one per quadrant, which is the index arithmetic's own shape: bases $00, $04, $09, $0E and $13, each plus a slope band of 0 to 4. The bytes say so too: every quadrant row starts on a horizontal and ends on a vertical (`00 .. 02`, `01 .. 02`, `00 .. 03`, `01 .. 03`), and the three between are that quadrant's three diagonals, $04-$0F in order. Bank 1 is banked, so the ROM offset is $7158." },
    .{ .name = "alpha_speedVectors", .kind = .physics, .bank = 0x1, .gb_addr = 0x71FB, .size = 0x40, .note = "Pinned in Step 13c: `alpha_getSpeedVector`'s sixteen arms, carried as code rather than as a table because that is what they are -- each `01 cc bb C9`, `LD BC,d16 / RET`, with B the Y speed and C the X speed in sign-magnitude. The near end is the first word of the jump table at 01:71DB, which `21 DB 71` at 01:71CB loads, and every one of its sixteen words is the previous plus four -- $71FB, $71FF .. $7237 -- so the arms are contiguous and the width is the table's. The far end is $71FB + $40 = 01:723B, `gamma_getAngle`, whose `CD C1 70` calls the distance routine the Alpha's own angle routine calls. `src/correspond.zig` checks every arm's opcode and return. Bank 1 is banked, so the ROM offset is $71FB." },
    .{ .name = "gamma_angleTable", .kind = .physics, .bank = 0x1, .gb_addr = 0x729C, .size = 0x20, .note = "Pinned in 1.0 Step 14: `gamma_getAngleFromTable`'s `.angleTable`, the Gamma's lunge direction per quadrant and slope band. The near end is `21 9C 72` at 01:7275, the only one in bank 1, and its reader adds `metroid_angleTableIndex` to it. The far end is $729C + $20 = 01:72BC, `gamma_convertSlopeToAngleIndex`, whose first instruction `FA 60 C4` reads the slope's high byte. The width is four cardinal entries and four rows of seven, one per quadrant: bases $00, $04, $0B, $12 and $19 (01:7255, $7259, $7260, $7264), each plus a band of 0 to 6. As the Alpha's, every quadrant row starts on a horizontal and ends on a vertical, and the five between are that quadrant's diagonals, $04-$17 in order. Bank 1 is banked, so the ROM offset is $729C." },
    .{ .name = "gamma_speedVectors", .kind = .physics, .bank = 0x1, .gb_addr = 0x7359, .size = 0x60, .note = "Pinned in 1.0 Step 14: `gamma_getSpeedVector`'s twenty-four arms, carried as code as the Alpha's are -- each `01 cc bb C9`, `LD BC,d16 / RET`. The near end is the first word of the jump table at 01:7329, which `21 29 73` at 01:7319 loads; its twenty-four words are $7359, $735D .. $73B5, each the previous plus four. The far end is $7359 + $60 = 01:73B9, `math_multiply_B_E_to_HL`. `src/correspond.zig` checks every arm. Bank 1 is banked, so the ROM offset is $7359." },
    .{ .name = "seekSamus_speedTable", .kind = .physics, .bank = 0x3, .gb_addr = 0x6BB1, .size = 0x21, .note = "Pinned in 1.0 Step 15: `enemy_seekSamus.speedTable`, the step a seeking Metroid adds to its Y and X, indexed by its `+$09` and `+$0A`. The near end is `21 B1 6B` at 03:6B97 and again at 03:6BA6, the routine's only two loads, each followed by `ADD HL,DE` with the index; the routine's own `RET` is the byte before, at 03:6BB0. The far end is $6BB1 + $21 = 03:6BD2, whose `21 0C C4` (`LD HL,$C40C`) is the next routine's first instruction and not a table byte. The width is the index's range: the Zeta's call (02:7377) steps by 2 from $10 and is stopped at D = $20 and E = $00, so it reads entries 0 to $20, thirty-three. The bytes rise from -5 at 0 through 0 at $0F-$11 to +5 at $20, which is the vector's shape: an index below the middle moves up or left. Bank 3 is banked, so the ROM offset is $EBB1." },
    .{ .name = "spiderDirectionTable", .kind = .physics, .bank = 0x0, .gb_addr = 0x20A9, .size = 0x40, .note = "Pinned in Step 14b: which way the rolling spider ball tries to move, per contact nibble, in four sixteen-byte rows. Both ends from the ROM, and each row separately. `poseFunc_spiderRoll` loads all four: `21 A9 20` at 00:10B7 and `21 C9 20` at 00:10BF for the first try, `21 B9 20` at 00:10FD and `21 D9 20` at 00:1105 for the second, each exactly once in bank 0, and each followed by `ADD HL,DE` with E the contact nibble -- so a row is sixteen and the rows are $10 apart, which is the width and the stride from four operands. The near end is `samus_damagePoseTable`'s far end, pinned independently in Step 10; the far end is $20A9 + $40 = 00:20E9, `collision_samusBGHitboxTop`, pinned independently in Phase 0a. The bytes are drawn from $00, $01, $02, $04 and $08 -- one direction bit or none, which is the alphabet the reader's four `BIT n` tests take -- and every row reads $00 at nibbles 0, 6 and 9, the three contact states no surface produces. Bank 0 is fixed, so the address is the offset." },
    .{ .name = "deathAnimationTable", .kind = .physics, .bank = 0x0, .gb_addr = 0x3042, .size = 0x20, .note = "Pinned in Step 15c, from the routine that reads it: `VBlank_deathSequence` does `LD HL,$3042` at 00:$2FED and adds `deathAnimTimer` less one, which runs from $20 down to 1, so the table is $20 bytes. Its far end is where `unusedDeathAnimation` begins at 00:$3062 (`LDH A,($97)` there is code, not a table byte). Each byte is the offset into a two-tile stride of object VRAM that one step of the death erases: the 32 values are $00-$1F, each once." },
    .{ .name = "queen_headFrames", .kind = .physics, .bank = 0x3, .gb_addr = 0x6FA2, .size = 0x6C, .note = "Pinned in 1.0 Step 6, from the routine that reads it: `queen_drawHead` loads `LD DE,$6FA2`, `$6FC6` and `$6FEA` at 03:$7027, $702E and $7035 for frames 1, 2 and anything else, and copies six bytes a row, so each frame is $24 bytes and three are $6C. Its far end is `queen_drawHead`'s own first instruction at 03:$700E, `FA F2 C3`, the resume arm's `LD A,($C3F2)`. Every byte is a window tile id: $B0-$FD, or $FF for the blank." },
    .{ .name = "queen_neckPatterns", .kind = .physics, .bank = 0x3, .gb_addr = 0x6C8E, .size = 0xBC, .note = "Pinned in 1.0 Step 19b, from the routine that reads it: `queen_setNeckBasePointer` loads `LD HL,$6C8E` at 03:$7477, the only load, and adds twice `queen_neckPattern`, 0-6: seven little-endian pointers, $6C9C, $6CB2, $6D00, $6CC8, $6D1E, $6D27 and $6CE7, each to a pattern inside the run. A pattern is $81, YX nibble pairs (Y signed), $00s and $80; `queen_moveNeck` reads it forwards to the $80 and back to the $81, so both are the reader's operands and carried. The far end is `queen_initialize` at 03:$6D4A, `21 00 C3`. Bank 3 is banked, so the ROM offset is $EC8E." },
    .{ .name = "queen_feet", .kind = .physics, .bank = 0x3, .gb_addr = 0x70C4, .size = 0x7C, .note = "Pinned in 1.0 Step 19b, from the routine that reads it: `queen_drawFeet` loads `LD HL,$70CA` and `LD DE,$7134` at 03:$7085 for the front foot (twelve cells, $708B) and `LD HL,$70C4` and `LD DE,$7124` at 03:$708F for the rear (sixteen, $7095). HL is a table of three pointers, to the frames' tile ids at $70D0, $70E0, $70F0 (rear) and $7100, $710C, $7118 (front); DE the cells' offsets from $9A00, $10 rear then $0C front, ending at 03:$7140, `queen_writeOam`'s `21 08 C3`. The byte before $70C4 is the routine's `RET`. Carried whole so the engine reads the ROM's pointers as offsets. Bank 3 is banked, so the ROM offset is $F0C4." },
    .{ .name = "queen_stateList", .kind = .physics, .bank = 0x3, .gb_addr = 0x7484, .size = 0x08, .note = "Pinned in 1.0 Step 19b: the Queen's fight, seven states and the $FF `queenStateFunc_pickNextState` wraps on (03:$784F `CP $FF`), so the terminator is the reader's operand. Loaded by `LD HL,$7484` at 03:$6DBC and 03:$785F, the only two; the far end is `queen_handleState` at 03:$748C, `FA C3 C3`. Bank 3 is banked, so the ROM offset is $F484." },
    .{ .name = "queen_walkSpeeds", .kind = .physics, .bank = 0x3, .gb_addr = 0x7C39, .size = 0x46, .note = "Pinned in 1.0 Step 19b: `queen_walk.walkSpeedTable`, the body's SCX step per frame, forwards to the $81 (03:$7C11 `CP $81`) and back from there to the $82 (03:$7C2A `CP $82`), both the reader's operands. Loaded by `LD DE,$7C39` at 03:$7C07, the only load, indexed by `queen_walkCounter`. The far end is the LCD handler at 03:$7C7F, `F5` (`PUSH AF`). Bank 3 is banked, so the ROM offset is $FC39." },
    .{ .name = "queen_bentNeckSprite", .kind = .physics, .bank = 0x3, .gb_addr = 0x7961, .size = 0x0F, .note = "Pinned in 1.0 Step 20b: five objects of three bytes, (Y, X, tile), the attribute written by the reader. Loaded by `LD DE,$7961` at 03:$799C, the only load; the reader stops on its destination, `CP $1C` at 03:$79AE, five objects from $C308, so the length is the reader's operand. The near end is `queenStateFunc_backwardWalk`'s `JP $7846` at 03:$795E; the far end is `queenStateFunc_stomachBombed` at 03:$7970, `FA A9 C3`. Bank 3 is banked, so the ROM offset is $F961." },
    .{ .name = "credits_paletteFade", .kind = .physics, .bank = 0x5, .gb_addr = 0x5877, .size = 0x08, .note = "Pinned in 1.0 Step 22, from the routine that reads it: `prepareCredits` begins `LD HL,$5877` at 05:$587F, the only load, and adds the countdown's top three bits (`AND $F0 / SWAP A / SRL A` at $5888), 0-7, so the table is eight bytes. Its far end is the routine's own first byte at $587F, the `21` of that load, so it cannot run one byte longer without being code. The bytes are $FF $FF $FB $EB $E7 $A7 $A3 $93, read from the end: the room fades from $93 to black." },
    .{ .name = "credits_starPositions", .kind = .physics, .bank = 0x5, .gb_addr = 0x5B14, .size = 0x20, .note = "Pinned in 1.0 Step 22, from the routine that reads it: `prepareCredits` loads `LD HL,$5B14` and `LD DE,$D600` at 05:$5906 and $5909, the only load, and copies `LD B,$10` bytes, half of the sixteen (y, x) pairs the two star routines walk (`LD B,$10` at $55DF and $5606, two bytes a star) -- the other half is never read. Its far end is `title_tilemap` at 05:$5B34, pinned in Step 7 from the other side, so $5B34 - $5B14 = $20 bytes, sixteen pairs." },
    .{ .name = "creditsText", .kind = .physics, .bank = 0x6, .gb_addr = 0x7920, .size = 0x4E3, .note = "Pinned in 1.0 Step 22, from the routine that reads it: `loadCreditsText` (00:$3C6A) maps bank 6 (`LD A,$06` at $3C6A), loads `LD HL,$7920` at $3C72 and copies a byte at a time to `creditsTextBuffer` until it has copied a $F0 (`CP $F0` at $3C82), so the size is to and with the first $F0 at or after $7920: $4E3 bytes, the $F0 at 06:$7E02. Rows are twenty characters, `VBlank_drawCreditsLine` (05:$403D) subtracting $21 from each, or a lone $F1 for a blank row; 54 rows and 170 blanks, which the test of `src/credits.zig` walks." },
    .{ .name = "metroidLCounterTable", .kind = .physics, .bank = 0x0, .gb_addr = 0x203B, .size = 0x48, .note = "Pinned in 1.0 Step 2a, from the routine that reads it: `tryPausing` does `LD HL,$203B` at 00:$2C94 and adds `metroidCountReal` to it, a BCD byte from $00 to $47, so the table is $48 bytes and a BCD count indexes it directly (the six $00 bytes after each decade are the indices a BCD count never takes). Its far end is `saveFile_magicNumber` at 00:$2083, `01 23 45 67 89 AB CD EF`, which the save code compares against and which is not a count. Each byte is the L counter the pause shows: the Metroids left in the area, in BCD, or $FF for the dashes." },
    .{ .name = "enemy_skreekJumpSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x5A7D, .size = 0x21, .note = "Pinned in 1.0 Step 11, from the routine that reads it: `enAI_skreek` loads `LD HL,$5A7D` at 02:5A18 (the sink) and 02:5A34 (the rise), the only two in the ROM. The rise indexes it with its timer from 0 while the timer is below 02:5A2C's `CP $21`, so $21 entries; the sink indexes it from $20 back down to 1. Its far end is the spit's header at 02:5A9E, the `11 9E 5A` operand of 02:5A66. Every entry is a speed of 0-5 pixels. Bank 2 is banked, so the ROM offset is $9A7D." },
    .{ .name = "enemy_drivelYSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x5B79, .size = 0x1E, .note = "Pinned in 1.0 Step 11. The drivel's vertical speed per call of its swoop, $80-terminated, and the terminator is the reader's operand: 02:5AFE's `CP $80` turns the drivel round, so it is carried. The near end is `21 79 5B` at 02:5AF4, the only one in the ROM; the far end is the $80 at $5B96, and $5B97 is the `21 97 5B` operand of the X table. Signed: the reader negates a negative entry and subtracts it (02:5B0A), which is the same byte as adding it. Bank 2 is banked, so the ROM offset is $9B79." },
    .{ .name = "enemy_drivelXSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x5B97, .size = 0x1E, .note = "Pinned in 1.0 Step 11. The drivel's horizontal speed, indexed as the Y table is. Its own $80 at $5BB4 is never read -- the Y table's terminator turns the drivel round first -- and is carried so the table is the ROM's whole; its far end is `.animate` at 02:5BB5, `F0 EF`, which reads `hEnemy.spawnFlag`. The near end is `21 97 5B` at 02:5B14, the only one in the ROM. Bank 2 is banked, so the ROM offset is $9B97." },
    .{ .name = "enemy_sineConcaveSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x682D, .size = 0x0A, .note = "Pinned in 1.0 Step 11. The slowing half of the halzyn's and the missile block's weave (M2RoS `.concaveSpeedTable`), ten entries indexed by `hEnemy.counter`, which 02:6783's `CP $0A` resets at ten. Six readers load it, `21 2D 68` at 02:67AD, $67B7, $67F4, $67FE, $681E and $6828; the far end is the convex table at $6837. Bank 2 is banked, so the ROM offset is $A82D." },
    .{ .name = "enemy_sineConvexSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x6837, .size = 0x0A, .note = "Pinned in 1.0 Step 11. The speeding half of the same weave (M2RoS `.convexSpeedTable`), indexed the same way. Six readers load it, `21 37 68` at 02:67B2, $67BC, $67EF, $67F9, $6819 and $6823; the far end is `enAI_septogg` at 02:6841, `CD 4E 6B`. Bank 2 is banked, so the ROM offset is $A837." },
    .{ .name = "blobThrower_data", .kind = .physics, .bank = 0x2, .gb_addr = 0x4FFE, .size = 0xD7, .note = "Pinned in 1.0 Step 12, from the routines that read it. The near end is `21 FE 4F` at 02:4DB1, `blobThrower_loadSprite`'s `LD HL,$4FFE`, which copies $3E bytes from here to $C300 (02:4DB7 `LD B,$3E`): the thrower's part list, fifteen four-byte parts and the $FF, which is $3D, and one byte over. The hitbox is the next four, `21 3B 50` at 02:4DBF and `LD B,$04` at 02:4DC5, so the list's copy takes the hitbox's first byte along. Then the three speed tables `enAI_blobThrower` reads at its action timer: `.speedTable_top` at $503F (`21 3F 50` at 02:4EE5, $4EED and $4F05), `.speedTable_middle` at $5071 (02:4EF5) and `.speedTable_bottom` at $50A3 (02:4EFD), each $32 bytes ending in the $80 `.moveSprites` tests at 02:4FDF, so the terminator is the reader's operand and is carried. The far end is $50D5, `.blobHeader_A`, the `11 D5 50` operand of 02:4F6E. Bank 2 is banked, so the ROM offset is $8FFE." },
    .{ .name = "blobMovementTables", .kind = .physics, .bank = 0x2, .gb_addr = 0x53D7, .size = 0xCA, .note = "Pinned in 1.0 Step 12. `blobMovementTable_A`-`D`, the four blobs' moves, one byte a move of two sign-and-magnitude nibbles, each $80-terminated, and the terminator is the reader's operand: `enAI_blobProjectile` tests it at 02:5387 `CP $80`. The reader takes its pointer from the slot, `+$09`/`+$0A`, which the four headers at 02:$50D5, $50E2, $50EF and $50FC set to $53D7, $5408, $5437 and $5463; the tables are consecutive, each ending on the byte before the next begins. The far end is `enAI_glowFly` at 02:54A1, `F0 EA`, its `LDH A,($EA)`. Bank 2 is banked, so the ROM offset is $93D7." },
    .{ .name = "arachnus_jumpSpeedTables", .kind = .physics, .bank = 0x2, .gb_addr = 0x52FC, .size = 0x73, .note = "Pinned in 1.0 Step 13. `enAI_arachnus.jumpSpeedTable_high` ($52FC, $32 bytes), `_mid` ($532E, $28) and `_low` ($5356, $19): Arachnus's bounces, one signed Y step a byte. The near ends are `21 FC 52` at 02:5152, `21 2E 53` at 02:5286 and `21 56 53` at 02:51B9. **They are one run and are read as one**: `.jump` (02:516E) indexes from whichever table it was handed by `arachnus_jumpCounter`, and landing on a table's closing $80 steps the counter past it onto the next table's first byte, so a counter started on `_high` bounces through all three. $80 and $81 are the reader's operands (02:5177, $5180), not lengths, and are carried. The far end is `enAI_blobProjectile` at 02:536F, `F0 E9`. Bank 2 is banked, so the ROM offset is $92FC." },
    .{ .name = "gameOverText", .kind = .physics, .bank = 0x0, .gb_addr = 0x3711, .size = 0x0A, .note = "Pinned in Step 15c, from the routine that reads it: `gameMode_dead` does `LD HL,$3711` at 00:$36E6 and copies to $9906 until it reads $80 (00:$36ED `CP $80`). Nine tile ids and the $80, which is the tenth byte; the eleventh, 00:$371B, is the `CALL $2384` that opens `gameMode_gameOver`." },
    .{ .name = "spiderBallOrientationTable", .kind = .physics, .bank = 0x6, .gb_addr = 0x7E03, .size = 0x100, .note = "Pinned in Step 14b: the rotation a d-pad press gives the spider ball at rest, 0 none, 1 counter-clockwise, 2 clockwise. The near end is `21 03 7E` at 00:106F, the only one in the ROM, after `LD A,$06 / LD ($D04E),A / LD ($2100),A` selects bank 6; the index is `SWAP` of the contact nibble plus the pad nibble in one byte, so the reader can reach exactly $100 entries and no other length. The far end is $7E03 + $100 = 06:7F03, where bank 6 is zero to its end. The bytes are only $00, $01 and $02, and rows 0, 6, 9 and F -- no contact, the two diagonal pairs, and embedded -- are all zero, the same three impossible states `spiderDirectionTable` leaves empty plus the one that cannot roll. Bank 6 is banked, so the ROM offset is $1BE03." },
    .{ .name = "samus_bombPoseTable", .kind = .physics, .bank = 0x1, .gb_addr = 0x55DD, .size = 0x1E, .note = "Pinned in Step 12c, and it is the one table in the 01:55DD-01:5671 run Step 12b left: the pose `bombs_samusAndBGCollision` throws Samus into, indexed by the pose she is in. Thirty entries, poses $00-$1D, the width `samus_damagePoseTable` and `samus_possibleShotDirections` carry. The near end is `21 DD 55` at 01:551D, the only one in bank 1; the far end is $55DD + $1E = 01:55FB, `samus_cannonXOffsets`, whose own near end Step 12b pinned by a different route -- so the run is now gapless from here to `destroyRespawningBlock`. The bytes are $11 and $12 for the first twenty poses, standing and ball knockback, with $12 landing exactly on the ball and spider poses; four zeros at $14-$17; $12 for $18 and $19; and $1A-$1D mapping to themselves. Bank 1 is banked, so the ROM offset is $55DD." },
    .{ .name = "samus_cannonXOffsets", .kind = .physics, .bank = 0x1, .gb_addr = 0x55FB, .size = 0x22, .note = "Pinned in Step 12b. Where the projectile is born, horizontally: `samusShoot` (01:4E8A) indexes it with `firingDirection*2 + samusFacingDirection`, so it is seventeen two-byte rows -- one per value the priority table below can return -- and $22 is the only length that shape allows. The near end is `21 FB 55` at 01:4EF6, the only one in bank 1; the far end is $55FB + $22 = 01:561D, where `samus_cannonYOffsetsByPose` begins, pinned independently by its own load. The nine tables from 01:55FB to 01:5671 are one gapless run and each one's far end is the next one's near end, so the run is self-checking: the last of them ends exactly on 01:5671, `destroyRespawningBlock`, whose address Step 12a pinned by a different route. The bytes are `00 00 18 1C 04 08 10 10 0E 12 10 10 10 10 10 10 0D 13` then fourteen more `10 10`: the rows the dispatch cannot reach all read $10, which is the centre, and the four it can are the four that differ -- the shape a sparse direction table has and not a shape SM83 code takes. Bank 1 is banked, so the ROM offset is $55FB." },
    .{ .name = "samus_cannonYOffsetsByPose", .kind = .physics, .bank = 0x1, .gb_addr = 0x561D, .size = 0x13, .note = "Pinned in Step 12b. One byte per pose: how far up Samus's cannon sits when she fires from it. Nineteen entries, poses $00-$12, which is where the table stops rather than the $1E the pose-transition tables carry -- the poses above $12 are the face-screen and Queen ones and `samus_possibleShotDirections` refuses every one of them, so no index above $12 can reach this. The near end is `21 1D 56` at 01:4EDB, the only one in bank 1; the far end is $561D + $13 = 01:5630, `samus_cannonYOffsetsByAim`. The nine tables from 01:55FB to 01:5671 are one gapless run and each one's far end is the next one's near end, so the run is self-checking: the last of them ends exactly on 01:5671, `destroyRespawningBlock`, whose address Step 12a pinned by a different route. The bytes are `17 1F 00 14 21 00 00 1D 00 15 15 00 00 00 00 1F 00 1F 00`, and the zeroes are exactly the poses whose `samus_possibleShotDirections` entry is $00 or $80 -- a cross-check between two tables that were pinned separately. Bank 1 is banked, so the ROM offset is $561D." },
    .{ .name = "samus_cannonYOffsetsByAim", .kind = .physics, .bank = 0x1, .gb_addr = 0x5630, .size = 0x13, .note = "Pinned in Step 12b. The second half of the Y offset, added to the per-pose one: which way she is aiming. Indexed by the firing direction bit, so its live entries are $01, $02, $04 and $08 and the rest are padding -- and it is nineteen bytes rather than sixteen because entry $10 is live too, which is `samus_possibleShotDirections`' morph-ball value reaching a table indexed by direction. The near end is `21 30 56` at 01:4EE7, the only one in bank 1; the far end is $5630 + $13 = 01:5643, `samus_shotDirectionPriority`. The nine tables from 01:55FB to 01:5671 are one gapless run and each one's far end is the next one's near end, so the run is self-checking: the last of them ends exactly on 01:5671, `destroyRespawningBlock`, whose address Step 12a pinned by a different route. The bytes are `00 00 00 00 F0 00 00 00 08 00 00 00 00 00 00 00 1F 00 00`: $F0 for up (sixteen pixels higher) and $08 for down, which is the sign pattern an aim offset has. Bank 1 is banked, so the ROM offset is $5630." },
    .{ .name = "samus_shotDirectionPriority", .kind = .physics, .bank = 0x1, .gb_addr = 0x5643, .size = 0x10, .note = "Pinned in Step 12b. Sixteen entries, one per d-pad combination `%dulr`, each naming the single direction the shot takes: down wins over up wins over right wins over left. The width is fixed by the index -- `samusShoot` swaps the input nibble and ANDs it with the pose's permitted directions, so the value can be any of $00-$0F and no more. The near end is `21 43 56` at 01:4ECF, the only one in bank 1; the far end is $5643 + $10 = 01:5653, `samus_possibleShotDirections`. The nine tables from 01:55FB to 01:5671 are one gapless run and each one's far end is the next one's near end, so the run is self-checking: the last of them ends exactly on 01:5671, `destroyRespawningBlock`, whose address Step 12a pinned by a different route. The bytes are `00 01 02 01 04 04 04 04 08 08 08 08 08 08 08 08`, drawn entirely from {$00,$01,$02,$04,$08} -- one set bit per entry, which is what a priority-resolution table looks like and what sixteen arbitrary bytes do not. Bank 1 is banked, so the ROM offset is $5643." },
    .{ .name = "samus_possibleShotDirections", .kind = .physics, .bank = 0x1, .gb_addr = 0x5653, .size = 0x1E, .note = "Pinned in Step 12b, and it is the gate on the whole of `samusShoot`: one byte per pose, `$00` no shooting, `$80` lay a bomb instead, otherwise `%0000dulr` of the directions this pose may fire in. Thirty entries, poses $00-$1D, the same width `samus_damagePoseTable` and `samus_bombedFallingPoses` carry and for the same reason -- the Queen poses push the id space that far. The near end is `21 53 56` at 01:4EA5, the only one in bank 1; the far end is $5653 + $1E = 01:5671, which is `destroyRespawningBlock` -- an address Step 12a pinned by its own route, so this table's length is fixed by something that owes nothing to it. The nine tables from 01:55FB to 01:5671 are one gapless run and each one's far end is the next one's near end, so the run is self-checking: the last of them ends exactly on 01:5671, `destroyRespawningBlock`, whose address Step 12a pinned by a different route. The bytes are `07 0F 00 07 03 80 80 0F 80 0F 0F 80 80 80 80 0F 80 0F 80 00` then ten more, and every one of them is $00, $03, $07, $0F or $80: five values, no others, which is the alphabet a direction-mask table has. The $80s land exactly on the six ball and spider poses plus the two ball knockbacks -- the poses that cannot hold a gun. Bank 1 is banked, so the ROM offset is $5653." },
    .{ .name = "projectile_beamSounds", .kind = .physics, .bank = 0x1, .gb_addr = 0x4FE5, .size = 0x09, .note = "Pinned in Step 12b. The sound-effect id `samusShoot` requests for each weapon type, indexed by `samusActiveWeapon` $00-$08 -- so nine entries, and the missile at $08 is the last index the weapon space has. The near end is `21 E5 4F`, which occurs twice in bank 1 (01:4F6F and 01:4FD6) and both are inside `samusShoot`: the ordinary exit and the plasma branch's, which is why two rather than one. The far end is $4FE5 + $09 = 01:4FEE, `getFirstEmptyProjectileSlot`, whose first bytes are `21 00 DD` -- `ld hl,$DD00`, the projectile array, which identifies the routine from the ROM alone. The bytes are `07 09 16 0B 0A 07 07 07 08`: the three unreachable weapon slots $05-$07 all hold $07, the plain beam's id, which is the padding pattern this game uses everywhere. **The port has no sound driver**, so what these feed is `!Sfx1`, a recording the way `!Song` is. Bank 1 is banked, so the ROM offset is $4FE5." },
    .{ .name = "projectile_waveSpeeds", .kind = .physics, .bank = 0x1, .gb_addr = 0x5183, .size = 0x11, .note = "Pinned in Step 12b. The wave beam's transverse velocity, one signed byte a frame, walked by an index that resets when it reads $80 -- so the $80 is part of the table and the length is seventeen, not sixteen. Carried with its terminator rather than converted to a length the way the arcs are, because the reader's reset is `cp $80` and reproducing that compare is what makes the address comment mean what it says. The near end is `21 83 51` at 01:50D4, the only one in bank 1; the far end is the terminator itself at $5193, and $5194 begins the unused alternate table M2RoS names -- which is why the far end here is stated by the $80 and not by the next pinned address. The bytes are `00 07 05 02 00 FE FB F9 00 F9 FB FE 00 02 05 07 80`: a sine, symmetric about its own halves and summing to zero, which is what a transverse oscillation is and what sixteen arbitrary bytes are not. Bank 1 is banked, so the ROM offset is $5183." },
    .{ .name = "projectile_missileSpeeds", .kind = .physics, .bank = 0x1, .gb_addr = 0x51A1, .size = 0x22, .note = "Pinned in Step 12b. The missile's acceleration curve: one speed per frame of its life, indexed by the projectile's own frame counter, ending in $FF -- and the reader holds the counter at the last index and uses the *second to last* entry from then on, so both the $FF and the $04 in front of it are load-bearing and the length is $22. The near end is `21 A1 51` at 01:51C8, the only one in bank 1; the far end is $51A1 + $22 = 01:51C3, where `F0` -- `ldh a,[hBeam_frameCouter]` -- begins the missile branch that reads it, which is the instruction immediately after the table and identifies the boundary from the ROM. The bytes climb $00 to $04 monotonically over 33 entries and then stop: a curve that never decreases is an acceleration table and is not a shape SM83 code takes. Bank 1 is banked, so the ROM offset is $51A1." },
    .{ .name = "projectile_missileSpriteTiles", .kind = .physics, .bank = 0x1, .gb_addr = 0x539D, .size = 0x09, .note = "Pinned in Step 12b. Which character a flying missile draws, indexed by its direction bit -- so nine entries, $00-$08, with only $01, $02, $04 and $08 reachable. The near end is `21 9D 53` at 01:5333, the only one in bank 1; the far end is $539D + $09 = 01:53A6, `projectile_missileSpriteAttrs`, and that table's own far end lands on 01:53AF, where `21 30 DD` -- `ld hl,$DD30`, the bomb array -- begins `bombBeam_layBomb` and identifies it from the ROM. The bytes are `00 98 98 00 99 00 00 00 99`: right and left share one character and up and down share the other, which is exactly what the attribute table beside it flips. Bank 1 is banked, so the ROM offset is $539D." },
    .{ .name = "projectile_missileSpriteAttrs", .kind = .physics, .bank = 0x1, .gb_addr = 0x53A6, .size = 0x09, .note = "Pinned in Step 12b. The attribute byte that goes with `projectile_missileSpriteTiles`, same index and same width. The near end is `21 A6 53` at 01:533E, the only one in bank 1; the far end is $53A6 + $09 = 01:53AF, `bombBeam_layBomb`, whose first bytes `21 30 DD` name the bomb array and identify the routine from the ROM alone. The bytes are `00 00 20 00 00 00 00 00 40`: $20 is the Game Boy's X flip and $40 its Y flip, on exactly the left and down entries -- which is the other half of the two-character claim in the tile table's note, and the two together are why these nine bytes are a sprite table rather than nine bytes. Bank 1 is banked, so the ROM offset is $53A6." },
    .{ .name = "enemy_hopperArcY", .kind = .physics, .bank = 0x2, .gb_addr = 0x6294, .size = 0x10, .note = "Pinned in Step 12f. The hopper's vertical speed per call of its jump, read forwards on the way up and backwards from $0F on the way down. The near end is `21 94 62`, which occurs exactly twice in the ROM, at 02:61FB and 02:625C -- the rise's `SUB (HL)` and the fall's `ADD A,(HL)` inside `enAI_hopper`; the far end is $6294 + $10 = 02:62A4, the `21 A4 62` operand of the X table beside it. Sixteen entries because the counter the reader indexes with is bounded by `CP $10` at 02:61E9. The bytes are `04 03 04 03 03 02 03 02 02 02 01 01 01 01 00 00`: a speed that decays to zero, which is what the top of an arc is. Bank 2 is banked, so the ROM offset is $A294." },
    .{ .name = "enemy_hopperArcX", .kind = .physics, .bank = 0x2, .gb_addr = 0x62A4, .size = 0x10, .note = "Pinned in Step 12f. The hopper's horizontal speed per call, indexed exactly as `enemy_hopperArcY` is. The near end is `21 A4 62`, which occurs exactly twice in the ROM, at 02:6203 and 02:6272, the rise's and the fall's; the far end is $62A4 + $10 = 02:62B4, `enAI_wallfire`, whose first bytes `21 E3 FF` -- `ld hl,hEnemy.spriteType` -- begin an AI and not a seventeenth speed. The bytes are `00 01 01 01 01 01 02 01 01 01 01 01 01 01 01 01`: no step on the first call of each half and one pixel a call after it, one of them two. Bank 2 is banked, so the ROM offset is $A2A4." },
    .{ .name = "enemy_gulluggYSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x5D85, .size = 0x3D, .note = "Pinned in Step 12f. The Gullugg's vertical speed per call of its clockwise circle, read by an index that resets when it reads $80 -- so, like `projectile_waveSpeeds`, the terminator is an operand of the reader and is carried. The near end is `21 85 5D` at 02:5CE9, the only one in the ROM, inside `enAI_gullugg`; the far end is the $80 itself at $5DC1, and $5DC2 is the `21 C2 5D` operand of the X table. Sixty speeds that sum to zero, which is what a closed loop is. M2RoS also names a counter-clockwise pair at $5D0C and $5D49 that no code addresses; it is not carried. Bank 2 is banked, so the ROM offset is $9D85." },
    .{ .name = "enemy_gulluggXSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x5DC2, .size = 0x3C, .note = "Pinned in Step 12f. The Gullugg's horizontal speed, indexed exactly as `enemy_gulluggYSpeeds` is and one entry shorter, because the index never reaches the $80's position here -- the Y table's terminator resets it first. The near end is `21 C2 5D` at 02:5CFE, the only one in the ROM; the far end is $5DC2 + $3C = 02:5DFE, `.animate`, whose `21 E3 FF` loads `hEnemy.spriteType` and is not a speed. Bank 2 is banked, so the ROM offset is $9DC2." },
    .{ .name = "enemy_chuteLeechXSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x5EC8, .size = 0x50, .note = "Pinned in Step 12f. The Chute Leech's horizontal speed per call of its descent, $80-terminated, and the terminator is the reader's operand: 02:5E71's `CP $80` is what ends the swing and restarts the AI, so it is carried. The near end is `21 C8 5E` at 02:5E6C, the only one in the ROM; the far end is the $80 at $5F17, and $5F18 is the `21 18 5F` operand of the Y table. The signs swing between runs of positive and negative, which is the leech drifting from side to side. Bank 2 is banked, so the ROM offset is $9EC8." },
    .{ .name = "enemy_chuteLeechYSpeeds", .kind = .physics, .bank = 0x2, .gb_addr = 0x5F18, .size = 0x4F, .note = "Pinned in Step 12f. The Chute Leech's vertical speed, indexed as the X table is and one entry shorter, because the X table's $80 ends the descent before its index reaches this far. The near end is `21 18 5F` at 02:5EBA, the only one in the ROM; the far end is $5F18 + $4F = 02:5F67, `enAI_pipeBug`, whose `F0 EF` reads `hEnemy.spawnFlag`. Every entry is $00-$03: a leech only ever goes down on its way down. Bank 2 is banked, so the ROM offset is $9F18." },
    .{ .name = "enemy_accelForwards", .kind = .physics, .bank = 0x2, .gb_addr = 0x6A96, .size = 0x18, .note = "Pinned in Step 12f. The speed `enemy_accelForwards` adds per call, indexed by `hEnemy.generalVar` after it is advanced and held at $17 -- so twenty-four entries, the first never read. The near end is `21 96 6A` at 02:6A8B, the only one in the ROM; the far end is $6A96 + $18 = 02:6AAE, `enemy_accelBackwards`, whose `C5 D5 E5` pushes are a routine's opening and not a speed. The bytes climb $00 to $04: an acceleration. Bank 2 is banked, so the ROM offset is $AA96." },
    .{ .name = "enemy_accelBackwards", .kind = .physics, .bank = 0x2, .gb_addr = 0x6AC9, .size = 0x18, .note = "Pinned in Step 12f. The mirror of `enemy_accelForwards`, the same curve negated. The near end is `21 C9 6A` at 02:6ABE, the only one in the ROM; the far end is $6AC9 + $18 = 02:6AE1, M2RoS's unreferenced `unknownProc_6AE1`, which opens with the same three pushes. Bank 2 is banked, so the ROM offset is $AAC9." },
    .{ .name = "weapon_damage", .kind = .physics, .bank = 0x2, .gb_addr = 0x43C8, .size = 0x0A, .note = "Pinned in Step 12b. How much health a hit takes off an enemy, indexed by weapon type $00-$09 -- ten entries, and the last of them is the bomb explosion, which is the highest type the game issues. The near end is `21 C8 43` in bank 2 at 02:4317, inside `enemy_getDamagedOrGiveDrop`'s beam arm, and it is the only one in the whole ROM, and the far end is $43C8 + $0A = 02:43D2, the stun tail the port already calls by that address -- `7D E0 FC` there, which is not a plausible continuation of a damage table and is the instruction the ledger already knows. The bytes are `01 02 04 08 1E 00 00 02 14 0A`: power, ice, wave, spazer doubling in order, the two unreachable slots reading $00, and the missile at $14 -- the ordering is the beam progression and is the evidence the index is the weapon type. Bank 2 is banked, so the ROM offset is $83C8." },
    .{ .name = "initial_save", .kind = .initial_save, .bank = 0x1, .gb_addr = 0x4E64, .size = 0x26, .note = "Pinned in Step 7: the save record a new game starts from, copied byte for byte into `saveBuffer` ($D800) by `createNewSave` (01:4E1C) before game mode $02 reads it. Both ends come from the ROM. The near end is the `LD HL,$4E64` in that routine's copy loop; the far end is $4E64+$26 = 01:4E8A, where `F0 81` -- `ldh a, [hInputRisingEdge]` -- begins `samusShoot`, and $26 is also the `LD B,$26` the loop counts down. Its 38 bytes are `save.fields` offsets 8-45 in order, which is the same record `inGame_saveAndLoad` writes to SRAM, so the two are one layout with two sources rather than two layouts. What it independently settles, and what nothing else in this repository could: the numbers the game itself starts from -- Samus at $07D4,$0648 and the camera at $07C0,$0640 in map bank $0F, which is trace frames 6 and 8 of the any% run exactly." },
    .{ .name = "item_names", .kind = .item_names, .bank = 0x1, .gb_addr = 0x58F1, .size = 0x120, .note = "Corrected in Step 11, and it was wrong at both ends: the entry read $5911/$1A0, which starts 32 bytes past the pointer table and runs 160 bytes past the strings into `drawEnemies`. Three independent statements of the real shape, none of them a listing. The pointer table at 01:$58F1 holds sixteen little-endian addresses and they are $5911, $5921 ... $5A01 - sixteen bytes apart, all sixteen, which no other string width can produce. The far end is code: 01:$5A11 is `FA 26 C4 A7 C8 21 00 C6`, `ld a,[numEnemies.active] / and a / ret z / ld hl,$C600`, which identifies drawEnemies from its own first instructions. And `gfx_itemFont` (05:$6C34, 32 tiles) drawn out is A at tile 0 and Z at tile 25, so a string byte is $C0 + tile - a fact about the graphics, reached without reading a string. $120 bytes: a 32-byte pointer table and sixteen 16-byte fixed-width names. See src/items.zig." },
    .{ .name = "audio_handle", .kind = .sound_entry, .bank = 0x4, .gb_addr = 0x4000, .size = 0x3, .note = "bank_004.asm opens with three `jp` trampolines at the bank base; this is the handleAudio entry. Bank 4 is the one bank M2RoS marks non-relocatable (docs/ROM Tour.md), which is why the entry points sit at fixed addresses. F8 replaces this bank wholesale rather than porting it." },
    .{ .name = "audio_silence", .kind = .sound_entry, .bank = 0x4, .gb_addr = 0x4003, .size = 0x3, .note = "bank_004.asm opens with three `jp` trampolines at the bank base; this is the silenceAudio entry. Bank 4 is the one bank M2RoS marks non-relocatable (docs/ROM Tour.md), which is why the entry points sit at fixed addresses. F8 replaces this bank wholesale rather than porting it." },
    .{ .name = "audio_initialize", .kind = .sound_entry, .bank = 0x4, .gb_addr = 0x4006, .size = 0x3, .note = "bank_004.asm opens with three `jp` trampolines at the bank base; this is the initializeAudio entry. Bank 4 is the one bank M2RoS marks non-relocatable (docs/ROM Tour.md), which is why the entry points sit at fixed addresses. F8 replaces this bank wholesale rather than porting it." },

    // ---- Bank 4's sound data (metroid2-audio Step 5) -----------------------
    //
    // The engine is being rewritten for the SPC700; its *data* is extracted and
    // placed in ARAM unchanged, so these entries are what the port reads.
    //
    // Every address here has the same primary evidence, stated once: M2RoS's
    // `bank_004.asm` assembles on its own, and `tools/get-bank4-sym.sh`
    // compares the assembled bank against the user's cartridge byte for byte,
    // withholding the symbols on a mismatch. So the labels are not a listing
    // being trusted -- they are labels on bytes that have been shown to be the
    // player's own. Each note below adds the arithmetic that closes
    // independently of that, because the labels are one source and the sizes
    // should not be.
    //
    // The block also tiles: $400C musicNotes -> $409E tempo -> $4113 wave ->
    // $41BB noise sets -> $4263 effect tables -> $42B3, which is `handleAudio`,
    // the first instruction of the bank's code. Every boundary is both the end
    // of one entry and the start of the next, so a wrong size anywhere shows up
    // as an overlap or a gap rather than as quietly wrong bytes.

    .{ .name = "audio_stateSizes", .kind = .sound_flags, .bank = 0x4, .gb_addr = 0x4009, .size = 0x3, .note = "Three size constants the engine reads out of its own bank rather than assembling in: the per-channel song processing state ($09), all four of them ($2D = 4 x $09 + 1, the extra byte being the song-level field the copy loop stops before), and the whole song processing state ($61). Checkable without a label: $2D / $09 is 5 and the engine's `copyChannelSongProcessingState` copies `channelSongProcessingStateSize` bytes, so the two constants are in the ratio the four channels plus a remainder demand. They sit between the three `jp` trampolines ($4000-$4009) and `musicNotes` ($400C)." },
    .{ .name = "audio_musicNotes", .kind = .sound_notes, .bank = 0x4, .gb_addr = 0x400C, .size = 0x92, .note = "The frequency table every note byte indexes. `loadNextSound` reaches it as `ld hl, musicNotes / add hl, bc` with bc = the note byte plus `songTranspose`, then reads two bytes into `songFrequency_working` low-then-high -- so the element is a 16-bit little-endian GB frequency and the table is indexed by *byte*, not by element. $92 = 146 bytes = 73 words. The far end is fixed independently: $400C + $92 = $409E, which is where the instruction timer arrays start, and those are self-evidencing (see audio_tempoTables)." },
    .{ .name = "audio_tempoTables", .kind = .sound_tempo, .bank = 0x4, .gb_addr = 0x409E, .size = 0x75, .note = "Nine instruction timer arrays, 13 bytes each: $75 = 117 = 9 x 13 exactly, and no other row width divides it into a plausible count. The width is confirmed by the data rather than by the labels: within every row, bytes 1-5 each double the one before and bytes 6-8 do the same (01 01 02 04 08 10 03 06 0c ... through 04 09 12 24 48 90 1b 36 6c ...), which is the whole/half/quarter/eighth note ladder a tempo table has to be, and the doubling only lines up at a stride of 13. `songInstruction_setInstructionTimerArrayPointer` ($F2) stores a pointer to one of these, and a note byte >= $9F indexes into it with bits 7 and 5 cleared." },
    .{ .name = "audio_wavePatterns", .kind = .sound_wave_patterns, .bank = 0x4, .gb_addr = 0x4113, .size = 0xA8, .note = "CH3 wave RAM contents, 16 bytes (32 four-bit samples) per pattern, copied by `writeToWavePatternRam`. $A8 = 168 = ten and a half 16-byte patterns, which is not a mistake: seven are reachable (`wavePatterns.wave0` through `.wave6`) and 56 bytes between wave1 and wave2 are unreferenced, so this is extracted as a blob with named offsets rather than as an array of patterns. The region's end is `songNoiseChannelOptionSets` at $41BB, whose own size divides exactly by 4 (see audio_songNoiseOptionSets), so a wrong boundary here would break that division." },
    .{ .name = "audio_songNoiseOptionSets", .kind = .sound_option_sets, .bank = 0x4, .gb_addr = 0x41BB, .size = 0xA8, .note = "The noise option sets a song's noise channel selects, four bytes each: sound length, envelope, polynomial counter, counter control -- the four bytes `setChannelOptionSet.noise` copies to rAUD4LEN and the three registers after it (`ld b, $04`). $A8 = 168 = 42 sets exactly. The counter-control byte is checkable on its own: the engine only ever writes $80 or $C0 there (restart, with or without the length-stop bit), so every fourth byte having only bits 6-7 set is a property of the region that a wrong start address would destroy." },
    .{ .name = "audio_songEffectTables", .kind = .sound_effect_table, .bank = 0x4, .gb_addr = 0x4263, .size = 0x50, .note = "Five 16-byte tables that `handleSongSoundChannelEffect` steps through for song effect indexes 2, 3, 4, 9 and $A. $50 = 80 = 5 x 16, and the five labels are 16 apart in the symbol file ($4263, $4273, $4283, $4293, $42A3), so the stride is stated twice. The far end is the strongest boundary in the block: $42B3 is `handleAudio`, the bank's first instruction, so this table cannot run one byte longer without overlapping code." },
    .{ .name = "audio_pausedOptionSets", .kind = .sound_option_sets, .bank = 0x4, .gb_addr = 0x487C, .size = 0x24, .note = "The option sets `handleAudio_paused` restores per channel when the game unpauses. $24 = 36 bytes. It sits inside the code region rather than in the data block at the bank's head, between `handleAudio_paused` ($4852) and `loadSongHeader` ($48A0), which is what bounds it: the two surrounding labels are code, so the run between them is exactly this table." },
    .{ .name = "audio_optionSets_square1", .kind = .sound_option_sets, .bank = 0x4, .gb_addr = 0x5A28, .size = 0x253, .note = "Square 1's option sets, five bytes each: `setChannelOptionSet.square1` copies to rAUD1SWEEP and the four registers after it (`ld b, $05`), i.e. NR10-NR14. $253 = 595 = 119 x 5 exactly, and 595 is divisible by no other plausible set width, so the count and the stride fall out of the size alone. Bounded below by `playNoiseSweepSfx` ($5A19, code) and above by `optionSets_noise` ($5C7B), whose own size then divides exactly by 4 -- the four option-set regions only all divide if all four boundaries are right." },
    .{ .name = "audio_optionSets_noise", .kind = .sound_option_sets, .bank = 0x4, .gb_addr = 0x5C7B, .size = 0xB0, .note = "The noise channel's own option sets, four bytes each (`setChannelOptionSet.noise`, rAUD4LEN and three after it). $B0 = 176 = 44 x 4 exactly. These are the sets the SFX routines select, distinct from `audio_songNoiseOptionSets` at the head of the bank, which is what the song's noise channel uses." },
    .{ .name = "audio_optionSets_square2", .kind = .sound_option_sets, .bank = 0x4, .gb_addr = 0x5D2B, .size = 0x14, .note = "Square 2's option sets, four bytes each (`setChannelOptionSet.square2`, rAUD2LEN and three after it -- square 2 has no sweep register, which is why it is four wide where square 1 is five). $14 = 20 = 5 x 4 exactly. Bounded above by `songSoundEffectInitialisationFunctionPointers_wave` at $5D3F." },
    .{ .name = "audio_optionSets_wave", .kind = .sound_option_sets, .bank = 0x4, .gb_addr = 0x5EFF, .size = 0x28, .note = "The wave channel's option sets, five bytes each (`setChannelOptionSet.wave`, rAUD3ENA and four after it -- NR30-NR34). $28 = 40 = 8 x 5 exactly. Bounded below by `waveSfx_playback_5` ($5EAA, code) and above by `playWaveSfx` ($5F27, code), and the run between those two code labels is $7D bytes of which the last $28 are this table." },
    .{ .name = "audio_songDataTable", .kind = .sound_song_table, .bank = 0x4, .gb_addr = 0x5F30, .size = 0x40, .note = "Thirty-two 16-bit little-endian pointers to song headers, indexed by song id. $40 = 64 = 32 x 2, and the count is confirmed by `audio_songStereoFlags` immediately after it being 32 bytes -- one flag per song. Read off the cartridge, thirty-one of the thirty-two land in $5F90-$7D09, the song data region; the exception is index $0F, which is $4769, inside `initializeAudio`. That is the `Nothing` song -- id $10, because `handleSong` does `dec a` before it indexes and refuses ids at or above $21, so the 32 entries are ids $01-$20, and it is a pointer into code, not data: see `src/audio_data.zig` for why that makes it the one entry the ARAM relocation cannot carry over." },
    .{ .name = "audio_songStereoFlags", .kind = .sound_flags, .bank = 0x4, .gb_addr = 0x5F70, .size = 0x20, .note = "One NR51 terminal-enable byte per song, 32 of them, matching `audio_songDataTable`'s 32 pointers exactly. Self-evidencing as a field: read off the cartridge every byte is $FF, $DE or $DB -- all four channels on, or one square muted on one side -- which is what a per-song stereo mask looks like and what no other 32-byte table in the bank looks like." },
    .{ .name = "audio_songData", .kind = .sound_song_data, .bank = 0x4, .gb_addr = 0x5F90, .size = 0x1E9B, .note = "Every song's header, channel section list and instruction stream, as one region: the structures point at each other freely and share sections between songs (five ids resolve to a header another id already uses), so there is no per-song boundary to cut on. The start is `audio_songDataTable`'s lowest target; the end is fixed by the cartridge rather than by a label -- $7E2B through $7FFF is entirely $00, and $7E2B is where M2RoS marks the bank's freespace. $1E9B = 7835 bytes. A header is 11 bytes (one music-note offset, then five little-endian pointers: instruction timer array, square 1, square 2, wave, noise), which the first one demonstrates: $5F90 reads $01 $4106 $5F9B $5FB3 $5FCB $5FDB, and the four channel pointers are the next four labels in address order." },
};

/// Classes named in the plan that are not yet pinned to an address. Listed
/// rather than omitted, so the coverage report in Step 5 can name what is
/// missing instead of silently covering less than it claims.
pub const pending = [_]struct { name: []const u8, why: []const u8 }{};

pub fn find(name: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Invariants
//
// These run without a ROM. They cannot tell us an address is *right*, but they
// catch the errors that transcription actually produces: a duplicated address,
// a size that runs past the end of its bank, a note someone forgot to write.
// ---------------------------------------------------------------------------

const rom_size: usize = 256 * 1024;

test "every entry has a non-empty note" {
    for (entries) |e| {
        std.testing.expect(e.note.len != 0) catch |err| {
            std.debug.print("entry '{s}' has no note\n", .{e.name});
            return err;
        };
    }
}

test "every entry lies inside the ROM" {
    for (entries) |e| {
        std.testing.expect(e.romEnd() <= rom_size) catch |err| {
            std.debug.print("entry '{s}' ends at {d}, past the {d}-byte ROM\n", .{ e.name, e.romEnd(), rom_size });
            return err;
        };
        try std.testing.expect(e.size != 0);
    }
}

test "no entry straddles a bank boundary" {
    // A banked read that runs off the end of $7FFF would silently read the next
    // bank's bytes, which is a real extraction bug rather than a theoretical one.
    for (entries) |e| {
        const bank_start = @as(usize, e.bank) * bank_size;
        std.testing.expect(e.romEnd() <= bank_start + bank_size) catch |err| {
            std.debug.print("entry '{s}' runs past the end of bank ${X}\n", .{ e.name, e.bank });
            return err;
        };
    }
}

test "no two entries overlap" {
    var sorted: [entries.len]Entry = entries;
    std.mem.sort(Entry, &sorted, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.romOffset() < b.romOffset();
        }
    }.lessThan);

    for (sorted[0 .. sorted.len - 1], sorted[1..]) |a, b| {
        std.testing.expect(a.romEnd() <= b.romOffset()) catch |err| {
            std.debug.print("'{s}' (${X}..${X}) overlaps '{s}' (${X}..${X})\n", .{
                a.name, a.romOffset(), a.romEnd(), b.name, b.romOffset(), b.romEnd(),
            });
            return err;
        };
    }
}

test "names are unique" {
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            std.testing.expect(!std.mem.eql(u8, a.name, b.name)) catch |err| {
                std.debug.print("duplicate entry name '{s}'\n", .{a.name});
                return err;
            };
        }
    }
}

test "banked addresses are in the paged window, bank 0 is not" {
    for (entries) |e| {
        if (e.bank == 0) {
            try std.testing.expect(e.gb_addr < 0x4000);
        } else {
            std.testing.expect(e.gb_addr >= 0x4000 and e.gb_addr <= 0x7FFF) catch |err| {
                std.debug.print("entry '{s}' in bank ${X} has address ${X:0>4}, outside $4000-$7FFF\n", .{ e.name, e.bank, e.gb_addr });
                return err;
            };
        }
    }
}

test "romOffset matches the bank arithmetic M2RoS's scripts use" {
    // gb2rom = (bank * 0x4000) + (addr & 0x3fff), spelled out here so a change
    // to romOffset has to disagree with the reference form to pass.
    for (entries) |e| {
        const expect = @as(usize, e.bank) * 0x4000 + (@as(usize, e.gb_addr) & 0x3fff);
        try std.testing.expectEqual(expect, e.romOffset());
    }
    // Two worked cases: bank 8 metatiles and the map bank $F scroll flags.
    try std.testing.expectEqual(@as(usize, 0x20880), (Entry{ .name = "", .kind = .metatiles, .bank = 8, .gb_addr = 0x4880, .size = 1, .note = "x" }).romOffset());
    try std.testing.expectEqual(@as(usize, 0x3C200), (Entry{ .name = "", .kind = .map_scroll_flags, .bank = 0xF, .gb_addr = 0x4200, .size = 1, .note = "x" }).romOffset());
}

test "bank 8's metatile block is gapless, closing on gfx_metAlpha" {
    // This is the arithmetic the metatile notes claim. Asserting it here means
    // the claim cannot rot silently if an address or size is edited.
    const order = [_][]const u8{
        "metatiles_plantBubbles", "metatiles_ruinsInside", "metatiles_finalLab",
        "metatiles_queen",        "metatiles_caveFirst",   "metatiles_surface",
        "metatiles_lavaCavesMid", "metatiles_lavaCavesEmpty", "metatiles_lavaCavesFull",
        "metatiles_ruinsExt",
    };
    var cursor = find("metatiles_plantBubbles").?.romOffset();
    for (order) |name| {
        const e = find(name).?;
        try std.testing.expectEqual(cursor, e.romOffset());
        cursor = e.romEnd();
    }
    try std.testing.expectEqual(find("gfx_metAlpha").?.romOffset(), cursor);
}

test "the enemy data pointer table is one pointer per screen across banks 9-F" {
    const map_banks = 7;
    const screens_per_bank = 256;
    const e = find("enemy_data_pointers").?;
    try std.testing.expectEqual(@as(usize, map_banks * screens_per_bank * 2), e.size);
}

test "map banks partition exactly, with 59 screens each" {
    var bank: u8 = 0x9;
    while (bank <= 0xF) : (bank += 1) {
        var buf: [40]u8 = undefined;
        const ptrs = find(try std.fmt.bufPrint(&buf, "map{X}_screen_pointers", .{bank})).?;
        var buf2: [40]u8 = undefined;
        const scroll = find(try std.fmt.bufPrint(&buf2, "map{X}_scroll_flags", .{bank})).?;
        var buf3: [40]u8 = undefined;
        const trans = find(try std.fmt.bufPrint(&buf3, "map{X}_transition_indexes", .{bank})).?;
        var buf4: [40]u8 = undefined;
        const screens = find(try std.fmt.bufPrint(&buf4, "map{X}_screens", .{bank})).?;

        // Contiguous, and filling the bank exactly.
        try std.testing.expectEqual(ptrs.romEnd(), scroll.romOffset());
        try std.testing.expectEqual(scroll.romEnd(), trans.romOffset());
        try std.testing.expectEqual(trans.romEnd(), screens.romOffset());
        try std.testing.expectEqual(@as(usize, bank + 1) * bank_size, screens.romEnd());

        // 59 screens of $100 bytes, matching docs/ROM Tour.md.
        try std.testing.expectEqual(@as(usize, 59 * 0x100), screens.size);
        // One pointer and one transition index per grid cell; one scroll byte per cell.
        try std.testing.expectEqual(@as(usize, 256 * 2), ptrs.size);
        try std.testing.expectEqual(@as(usize, 256 * 2), trans.size);
        try std.testing.expectEqual(@as(usize, 256), scroll.size);
    }
}

test "the 255-entry enemy id space is consistent across its four tables" {
    try std.testing.expectEqual(@as(usize, 255 * 2), find("enemy_header_pointers").?.size);
    try std.testing.expectEqual(@as(usize, 255 * 2), find("enemy_hitbox_pointers").?.size);
    try std.testing.expectEqual(@as(usize, 255), find("enemy_damage").?.size);
}

test "pending entries are named and explained" {
    for (pending) |p| {
        try std.testing.expect(p.name.len != 0);
        try std.testing.expect(p.why.len != 0);
        try std.testing.expect(find(p.name) == null); // pending means not yet in the table
    }
}

// ---------------------------------------------------------------------------
// Verification against the ROM
//
// The invariants above check the table against itself. This checks it against
// the bytes, which is what actually promotes "M2RoS says so" to "we verified
// it". The method is shape: if `solidity_thresholds` really points at eight
// four-byte rows, every fourth byte there is $FF - and if the address were
// wrong by even one byte, it would not be.
//
// A shape check can pass on a wrong address by luck, so this is evidence rather
// than proof. It is strong evidence: the predicates below are chosen so that a
// misaligned or misattributed region fails them.
// ---------------------------------------------------------------------------

pub const Failure = struct {
    entry: []const u8,
    detail: []const u8,
};

pub const Verification = struct {
    checked: usize = 0,
    failures: std.ArrayList(Failure) = .empty,

    pub fn deinit(self: *Verification, allocator: std.mem.Allocator) void {
        for (self.failures.items) |f| allocator.free(f.detail);
        self.failures.deinit(allocator);
    }

    pub fn ok(self: Verification) bool {
        return self.failures.items.len == 0;
    }
};

fn readWord(rom: []const u8, at: usize) u16 {
    return @as(u16, rom[at]) | (@as(u16, rom[at + 1]) << 8);
}

/// Run every shape check we have. `rom` must already have passed ingest.
pub fn verifyAgainstRom(allocator: std.mem.Allocator, rom: []const u8) !Verification {
    var v: Verification = .{};
    errdefer v.deinit(allocator);

    const add = struct {
        fn f(a: std.mem.Allocator, ver: *Verification, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
            try ver.failures.append(a, .{ .entry = name, .detail = try std.fmt.allocPrint(a, fmt, args) });
        }
    }.f;

    // Solidity: eight rows of four bytes, each row terminated $FF.
    {
        const e = find("solidity_thresholds").?;
        v.checked += 1;
        var row: usize = 0;
        while (row < 8) : (row += 1) {
            const term = rom[e.romOffset() + row * 4 + 3];
            if (term != 0xFF) {
                try add(allocator, &v, e.name, "row {d} ends ${X:0>2}, expected $FF", .{ row, term });
                break;
            }
        }
    }

    // Scroll flags: only bits 0-3 are defined (right/left/up/down), so no byte
    // in these regions may have a high nibble.
    {
        var bank: u8 = 0x9;
        while (bank <= 0xF) : (bank += 1) {
            var buf: [40]u8 = undefined;
            const e = find(try std.fmt.bufPrint(&buf, "map{X}_scroll_flags", .{bank})).?;
            v.checked += 1;
            for (rom[e.romOffset()..e.romEnd()], 0..) |b, i| {
                if (b & 0xF0 != 0) {
                    try add(allocator, &v, e.name, "byte {d} is ${X:0>2}; only bits 0-3 are defined", .{ i, b });
                    break;
                }
            }
        }
    }

    // Screen pointers must address the screen-body region of their own bank,
    // i.e. $4500-$8000. A wrong base address would scatter these immediately.
    {
        var bank: u8 = 0x9;
        while (bank <= 0xF) : (bank += 1) {
            var buf: [40]u8 = undefined;
            const e = find(try std.fmt.bufPrint(&buf, "map{X}_screen_pointers", .{bank})).?;
            v.checked += 1;
            var i: usize = 0;
            var bad: usize = 0;
            while (i < e.size) : (i += 2) {
                const w = readWord(rom, e.romOffset() + i);
                if (w < 0x4500 or w >= 0x8000) bad += 1;
            }
            // Unused grid cells exist, so allow some slack; a wrong address
            // produces overwhelmingly bad values, not a handful.
            if (bad * 4 > e.size / 2) {
                try add(allocator, &v, e.name, "{d} of {d} pointers fall outside $4500-$8000", .{ bad, e.size / 2 });
            }
        }
    }

    // Pointer tables that must address their own bank's paged window.
    for ([_][]const u8{ "enemy_header_pointers", "enemy_hitbox_pointers", "door_pointers" }) |name| {
        const e = find(name).?;
        v.checked += 1;
        var i: usize = 0;
        var bad: usize = 0;
        while (i < e.size) : (i += 2) {
            const w = readWord(rom, e.romOffset() + i);
            if (w < 0x4000) bad += 1;
        }
        if (bad * 4 > e.size / 2) {
            try add(allocator, &v, e.name, "{d} of {d} pointers are below $4000", .{ bad, e.size / 2 });
        }
    }

    // The pose sprite-id tables. Two checks, and the second is the one that
    // would fail on a one-byte shift: every byte must be a sprite id the samus
    // metasprite pointer table actually holds, and the two sixteen-entry tables
    // must be zero at exactly the ten slots the facing/d-pad index cannot
    // produce - "no facing direction" and "both left and right" in each of the
    // four vertical rows, plus the whole impossible up-and-down row.
    {
        const ids = find("metasprite_samus_pointers").?.size / 2;
        for ([_][]const u8{
            "pose_sprites_jump",
            "pose_sprites_spin",
            "pose_sprites_standing",
            "pose_sprites_running",
        }) |name| {
            const e = find(name).?;
            v.checked += 1;
            for (rom[e.romOffset()..e.romEnd()], 0..) |b, i| {
                if (b >= ids) {
                    try add(allocator, &v, e.name, "byte {d} is sprite ${X:0>2}; the set holds {d}", .{ i, b, ids });
                    break;
                }
            }
        }
        const impossible = [_]usize{ 0, 3, 4, 7, 8, 11, 12, 13, 14, 15 };
        for ([_][]const u8{ "pose_sprites_jump", "pose_sprites_standing" }) |name| {
            const e = find(name).?;
            v.checked += 1;
            for (impossible) |i| {
                if (rom[e.romOffset() + i] != 0x00) {
                    try add(allocator, &v, e.name, "slot {d} is ${X:0>2}; that facing cannot be indexed", .{ i, rom[e.romOffset() + i] });
                    break;
                }
            }
        }
    }

    // The sound driver's three trampolines must each be a `jp nn` ($C3).
    for ([_][]const u8{ "audio_handle", "audio_silence", "audio_initialize" }) |name| {
        const e = find(name).?;
        v.checked += 1;
        const op = rom[e.romOffset()];
        if (op != 0xC3) {
            try add(allocator, &v, e.name, "opcode is ${X:0>2}, expected $C3 (jp nn)", .{op});
        }
    }

    // ---- Bank 4's sound data (metroid2-audio Step 5) ----------------------
    //
    // Each of these is a property the region has and its neighbours do not, so
    // a wrong start address breaks it. None of them consults M2RoS.

    // The instruction timer arrays are the note-length ladder: inside each
    // 13-byte row, bytes 1-5 double and bytes 6-8 double. The doubling only
    // lines up at a stride of 13, which is what makes this a check on the
    // address and the width at once rather than on the contents.
    {
        const e = find("audio_tempoTables").?;
        v.checked += 1;
        const stride = 13;
        var row: usize = 0;
        rows: while (row * stride < e.size) : (row += 1) {
            const r = rom[e.romOffset() + row * stride ..][0..stride];
            for ([_]usize{ 1, 2, 3, 4, 6, 7 }) |i| {
                const want: u8 = r[i] *% 2;
                if (r[i + 1] != want) {
                    try add(allocator, &v, e.name, "row {d} byte {d} is ${X:0>2}, not twice ${X:0>2}", .{ row, i + 1, r[i + 1], r[i] });
                    break :rows;
                }
            }
        }
    }

    // Every fourth byte of the song's noise option sets is the counter-control
    // byte, and the engine only ever writes $80 or $C0 there: restart, with or
    // without "stop when the length runs out". Nothing else in the block has
    // that shape at a stride of four.
    {
        const e = find("audio_songNoiseOptionSets").?;
        v.checked += 1;
        var i: usize = 3;
        while (i < e.size) : (i += 4) {
            const b = rom[e.romOffset() + i];
            if (b & 0x3F != 0) {
                try add(allocator, &v, e.name, "set {d}'s counter control is ${X:0>2}; only bits 6-7 are written", .{ i / 4, b });
                break;
            }
        }
    }

    // The song table's pointers must address the song data region -- except
    // index $10, `Nothing`, which points into `initializeAudio`. That exception
    // is asserted rather than tolerated: it is the pointer the ARAM relocation
    // has to refuse, so if it ever stopped being the only one, the relocation's
    // single special case would be silently wrong.
    {
        const table = find("audio_songDataTable").?;
        const data = find("audio_songData").?;
        v.checked += 1;
        const lo: u16 = data.gb_addr;
        const hi: u16 = @intCast(data.gb_addr + data.size);
        var i: usize = 0;
        var outside: usize = 0;
        while (i < table.size) : (i += 2) {
            const p = readWord(rom, table.romOffset() + i);
            const in_data = p >= lo and p < hi;
            // Table index $0F is song id $10, `Nothing`: `handleSong` does
            // `dec a` before it indexes, so the id and the index are never the
            // same number.
            if (i / 2 == 0x0F) {
                if (in_data) try add(allocator, &v, table.name, "index $0F is ${X:0>4}, inside the song data; it should be the pointer into initializeAudio", .{p});
            } else if (!in_data) {
                outside += 1;
                if (outside == 1)
                    try add(allocator, &v, table.name, "index ${X:0>2} is ${X:0>4}, outside the song data ${X:0>4}-${X:0>4}", .{ i / 2, p, lo, hi });
            }
        }
    }

    // One stereo flag per song, and each is an NR51 terminal mask the engine
    // actually emits. A table of anything else would not be all $FF/$DE/$DB.
    {
        const e = find("audio_songStereoFlags").?;
        const table = find("audio_songDataTable").?;
        v.checked += 1;
        if (e.size * 2 != table.size)
            try add(allocator, &v, e.name, "{d} flags for {d} songs", .{ e.size, table.size / 2 });
        for (rom[e.romOffset()..e.romEnd()], 0..) |b, i| {
            if (b != 0xFF and b != 0xDE and b != 0xDB) {
                try add(allocator, &v, e.name, "song ${X:0>2}'s flag is ${X:0>2}, not one of the masks the engine writes", .{ i, b });
                break;
            }
        }
    }

    // The first song header, read as the format says it is laid out: a
    // music-note offset, then five little-endian pointers. The timer pointer
    // must land on a tempo table boundary and the four channel pointers must
    // be inside the song data, in ascending order -- the header is 11 bytes and
    // any other width puts at least one of those six fields somewhere invalid.
    {
        const e = find("audio_songData").?;
        const tempo = find("audio_tempoTables").?;
        v.checked += 1;
        const tp = readWord(rom, e.romOffset() + 1);
        if (tp < tempo.gb_addr or tp >= tempo.gb_addr + tempo.size or (tp - tempo.gb_addr) % 13 != 0)
            try add(allocator, &v, e.name, "the first header's timer pointer ${X:0>4} is not a tempo table boundary", .{tp});
        var prev: u16 = @intCast(e.gb_addr);
        for (0..4) |c| {
            const p = readWord(rom, e.romOffset() + 3 + c * 2);
            if (p <= prev or p >= e.gb_addr + e.size) {
                try add(allocator, &v, e.name, "the first header's channel {d} pointer ${X:0>4} is not inside the song data after ${X:0>4}", .{ c, p, prev });
                break;
            }
            prev = p;
        }
    }

    // The bank's data block tiles with no gaps, from the state-size constants
    // to `handleAudio`'s first instruction. Each boundary is stated twice --
    // once as an end, once as a start -- so a wrong size shows up here rather
    // than as quietly wrong bytes.
    {
        const chain = [_][]const u8{
            "audio_stateSizes",  "audio_musicNotes",         "audio_tempoTables",
            "audio_wavePatterns", "audio_songNoiseOptionSets", "audio_songEffectTables",
        };
        v.checked += 1;
        for (chain[0 .. chain.len - 1], chain[1..]) |a_name, b_name| {
            const a = find(a_name).?;
            const b = find(b_name).?;
            if (a.gb_addr + a.size != b.gb_addr)
                try add(allocator, &v, a.name, "ends at ${X:0>4}, but {s} starts at ${X:0>4}", .{ a.gb_addr + a.size, b.name, b.gb_addr });
        }
        const last = find(chain[chain.len - 1]).?;
        if (last.gb_addr + last.size != 0x42B3)
            try add(allocator, &v, last.name, "ends at ${X:0>4}, not at handleAudio's $42B3", .{last.gb_addr + last.size});
    }

    // The song data's far end is the cartridge's own statement, not a label:
    // everything from there to the end of the bank is $00.
    {
        const e = find("audio_songData").?;
        v.checked += 1;
        const bank_end = (@as(usize, e.bank) + 1) * bank_size;
        for (rom[e.romEnd()..bank_end], 0..) |b, i| {
            if (b != 0) {
                try add(allocator, &v, e.name, "byte ${X:0>4} past the end is ${X:0>2}, not the bank's $00 freespace", .{ e.gb_addr + e.size + i, b });
                break;
            }
        }
    }

    return v;
}

test "shape checks accept well-formed data and reject a one-byte shift" {
    const allocator = std.testing.allocator;
    const rom = try allocator.alloc(u8, rom_size);
    defer allocator.free(rom);
    @memset(rom, 0);

    // Plant correctly shaped content at each verified address.
    const sol = find("solidity_thresholds").?;
    for (0..8) |row| rom[sol.romOffset() + row * 4 + 3] = 0xFF;

    var bank: u8 = 0x9;
    while (bank <= 0xF) : (bank += 1) {
        var b1: [40]u8 = undefined;
        const scroll = find(try std.fmt.bufPrint(&b1, "map{X}_scroll_flags", .{bank})).?;
        @memset(rom[scroll.romOffset()..scroll.romEnd()], 0x0F);

        var b2: [40]u8 = undefined;
        const ptrs = find(try std.fmt.bufPrint(&b2, "map{X}_screen_pointers", .{bank})).?;
        var i: usize = 0;
        while (i < ptrs.size) : (i += 2) {
            rom[ptrs.romOffset() + i] = 0x00;
            rom[ptrs.romOffset() + i + 1] = 0x45;
        }
    }
    for ([_][]const u8{ "enemy_header_pointers", "enemy_hitbox_pointers", "door_pointers" }) |name| {
        const e = find(name).?;
        var i: usize = 0;
        while (i < e.size) : (i += 2) {
            rom[e.romOffset() + i + 1] = 0x50;
        }
    }
    for ([_][]const u8{ "audio_handle", "audio_silence", "audio_initialize" }) |name| {
        rom[find(name).?.romOffset()] = 0xC3;
    }
    for ([_][]const u8{ "pose_sprites_jump", "pose_sprites_standing" }) |name| {
        const e = find(name).?;
        for ([_]usize{ 1, 2, 5, 6, 9, 10 }) |i| rom[e.romOffset() + i] = 0x01;
    }
    // Bank 4's sound data. The freespace check needs nothing planted: the
    // buffer is already zero, which is what the real bank's tail is.
    {
        const tempo = find("audio_tempoTables").?;
        var row: usize = 0;
        while (row * 13 < tempo.size) : (row += 1) {
            const r = rom[tempo.romOffset() + row * 13 ..][0..13];
            r[1] = 1;
            for ([_]usize{ 1, 2, 3, 4 }) |i| r[i + 1] = r[i] *% 2;
            r[6] = 3;
            for ([_]usize{ 6, 7 }) |i| r[i + 1] = r[i] *% 2;
        }
        const noise = find("audio_songNoiseOptionSets").?;
        var i: usize = 3;
        while (i < noise.size) : (i += 4) rom[noise.romOffset() + i] = 0x80;

        const data = find("audio_songData").?;
        const table = find("audio_songDataTable").?;
        var s: usize = 0;
        while (s < table.size) : (s += 2) {
            // $10 is `Nothing`, which points into the engine's own code.
            const target: u16 = if (s / 2 == 0x0F) 0x4769 else @intCast(data.gb_addr + 0x100);
            rom[table.romOffset() + s] = @truncate(target);
            rom[table.romOffset() + s + 1] = @intCast(target >> 8);
        }
        @memset(rom[find("audio_songStereoFlags").?.romOffset()..find("audio_songStereoFlags").?.romEnd()], 0xFF);

        // A well-formed first header: note offset, a tempo table boundary, then
        // four ascending channel pointers inside the song data.
        rom[data.romOffset()] = 0x01;
        rom[data.romOffset() + 1] = @truncate(tempo.gb_addr);
        rom[data.romOffset() + 2] = @intCast(tempo.gb_addr >> 8);
        for (0..4) |c| {
            const p: u16 = @intCast(data.gb_addr + 0x20 + c * 0x10);
            rom[data.romOffset() + 3 + c * 2] = @truncate(p);
            rom[data.romOffset() + 4 + c * 2] = @intCast(p >> 8);
        }
    }

    var v = try verifyAgainstRom(allocator, rom);
    defer v.deinit(allocator);
    try std.testing.expect(v.ok());
    try std.testing.expect(v.checked > 15);

    // Now break exactly one thing: shift the solidity terminators by a byte,
    // which is what a one-byte address error would look like.
    for (0..8) |row| {
        rom[sol.romOffset() + row * 4 + 3] = 0x00;
        rom[sol.romOffset() + row * 4 + 2] = 0xFF;
    }
    var v2 = try verifyAgainstRom(allocator, rom);
    defer v2.deinit(allocator);
    try std.testing.expect(!v2.ok());
    try std.testing.expectEqualStrings("solidity_thresholds", v2.failures.items[0].entry);
}
