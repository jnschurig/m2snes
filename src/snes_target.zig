//! The SNES target: what mode we run in, where things live in VRAM, and how a
//! Game Boy tile id becomes a SNES character index.
//!
//! Everything here is a *decision*, not a derivation, which is why it is one
//! small module rather than constants scattered through the converters. The
//! ROM does not tell us what background mode to use; it tells us what shape the
//! data is, and this file records what we chose to do with that shape. Each
//! decision carries why, because the reason is what a later step needs when it
//! wants to change one.
//!
//! ## Mode 1, play field on BG3
//!
//!   BG1  4bpp   unused in Phase 0a - kept free for the wider view and parallax
//!   BG2  4bpp   the HUD band below the play window
//!   BG3  2bpp   the play field
//!   OBJ  4bpp   Samus and enemies (the SNES gives no choice here)
//!
//! BG3 at 2bpp is what makes the requirement's word "reinterpretation" true: a
//! Game Boy 2bpp tile and a SNES 2bpp tile are the same sixteen bytes in the
//! same order, so the play field's graphics convert by copying. The cost is a
//! four-colour ceiling on BG3, and the DMG source has four shades, so the
//! ceiling is not reachable.
//!
//! ## The tile id space is signed, and it overlaps OBJ
//!
//! The door-script handler at 0:$26EB fills a six-byte VRAM request block at
//! $FFB1-$FFB6 (src lo/hi, dest lo/hi, len lo/hi) that the opcode does not
//! carry:
//!
//!   LOAD_bg  ($B1)   dest $9000, len $0800   128 tiles, ids $00-$7F
//!   LOAD_spr ($B2)   dest $8B00, len $0400    64 tiles, ids $B0-$EF
//!
//! So the background reads tiles through the $8800 *signed* addressing mode,
//! based at $9000: id 0 is at $9000 and id $FF is at $8FF0, spanning VRAM
//! $8800-$97FF. `LOAD_spr`'s window sits inside that span, which is why
//! `metatiles_surface` reaches id $EF and `metatiles_queen` reaches $FE - the
//! background genuinely draws with tiles the sprite loader put there.
//!
//! The SNES cannot reproduce that sharing: BG3 is 2bpp and OBJ is always 4bpp,
//! so the same art has to exist in both depths. `chr.zig` converts a sheet once
//! per depth and `layout.zig` charges for both.

const std = @import("std");

// ---- Screen ---------------------------------------------------------------

/// The play window, in pixels. `01-requirements.md` F7 pins these and requires
/// that camera, spawn windows, and streaming all be expressed in terms of them.
pub const view_w: u16 = 160;
pub const view_h: u16 = 144;
/// The play *area*: the window less the 8-line HUD band. Step 7 measured the
/// original's split and found it is the window at WY=136/WX=7, not a mid-frame
/// scroll write, so the band is 8 lines and the world is 136.
pub const play_h: u16 = 136;
pub const hud_h: u16 = view_h - play_h;

/// The SNES frame the play window sits inside.
pub const screen_w: u16 = 256;
pub const screen_h: u16 = 224;

// ---- Layers ---------------------------------------------------------------

pub const bg_mode: u3 = 1;

pub const Depth = enum(u3) {
    bpp2 = 2,
    bpp4 = 4,

    pub fn bytesPerTile(self: Depth) usize {
        return switch (self) {
            .bpp2 => 16,
            .bpp4 => 32,
        };
    }
};

/// Which layer the play field draws on, and at what depth.
pub const play_layer: u2 = 3;
pub const play_depth: Depth = .bpp2;
pub const obj_depth: Depth = .bpp4;

// ---- VRAM -----------------------------------------------------------------

/// The background tile id space is 8 bits, so BG3's character window is 256
/// characters wide - exactly the span the Game Boy's signed addressing reaches.
pub const bg_chars: usize = 256;
pub const bg_char_bytes: usize = bg_chars * 16; // 4 KiB

/// One screen is 16x16 metatiles = 32x32 tiles = 256x256 pixels, which is
/// exactly one SNES 32x32 tilemap. The Game Boy's tilemap is the same shape, so
/// edge streaming ports across unchanged rather than being redesigned.
pub const tilemap_w: usize = 32;
pub const tilemap_h: usize = 32;
pub const tilemap_words: usize = tilemap_w * tilemap_h;
pub const tilemap_bytes: usize = tilemap_words * 2;

/// Game Boy VRAM addresses, kept so the converters can talk about door-script
/// destinations in the units the ROM states them in.
pub const gb_vram_base: u16 = 0x8000;
/// Base of the signed background addressing mode: id 0 lives here.
pub const gb_bg_signed_base: u16 = 0x9000;
/// Lowest address the background window reaches - id $80.
pub const gb_bg_window_lo: u16 = 0x8800;
/// One past the highest - id $7F ends at $97FF.
pub const gb_bg_window_hi: u16 = 0x9800;
/// Game Boy background tilemap 1, which is the one the queen-head copies write.
pub const gb_tilemap1_base: u16 = 0x9C00;
pub const gb_tilemap0_base: u16 = 0x9800;
pub const gb_tilemap_bytes: u16 = 0x400;

// ---- SNES VRAM map ---------------------------------------------------------
//
// Word addresses, because that is the unit $2116 takes. Every base below sits
// on the granularity its register demands: BG character bases move in 4K-word
// steps (BG34NBA/BG12NBA), tilemap bases in 1K-word steps (BGnSC), and the
// object base in 8K-word steps (OBSEL). A base that violated its granularity
// would silently round down in hardware, so the test at the bottom checks all
// of them rather than trusting the arithmetic here.

pub const vram_words: usize = 0x8000;

/// BG3's characters: the play field's 256 tiles, 8 words each at 2bpp.
pub const bg3_char_base: u16 = 0x0000;
/// BG3's tilemap: one 32x32 screen.
pub const bg3_map_base: u16 = 0x0800;
/// BG2's tilemap: the HUD band.
pub const bg2_map_base: u16 = 0x0C00;
/// BG1's character base, BG12NBA's low nibble: the readout's glyphs.
pub const bg12_char_base: u16 = 0x1000;
/// Objects.
pub const obj_char_base: u16 = 0x6000;
/// BG2's, BG12NBA's high nibble: the objects' own, since Step 24g. The Game
/// Boy's window reads $8800-$8FFF, which are the bytes its objects read as ids
/// $80-$FF, and BG2 is 4bpp like them, so one copy serves both as it does there.
pub const bg2_char_base: u16 = obj_char_base;

/// Words per character at each depth.
pub fn charWords(d: Depth) u16 {
    return @intCast(d.bytesPerTile() / 2);
}

/// The VRAM byte offset, relative to `gb_vram_base`, that background tile `id`
/// occupies under the signed addressing mode. This is the mapping `screens.zig`
/// renders through, restated here because the converters need it too.
pub fn gbTileOffset(id: u8) usize {
    const signed: i32 = @as(i8, @bitCast(id));
    return @intCast(@as(i32, gb_bg_signed_base - gb_vram_base) + signed * 16);
}

/// The character index a Game Boy background tile id becomes.
///
/// It is the identity. The alternative was to lay the converted character
/// region out in Game Boy VRAM *address* order, which would have made this a
/// rotation by 128 and put a byte-level surprise between what a tilemap word
/// says and what the tileset dump shows. Keeping the id is worth the cost,
/// which is that the *copy destinations* rotate instead - see `gbDestToChar`,
/// and there are a few dozen of those against 1103 metatiles.
pub fn charForTileId(id: u8) u16 {
    return id;
}

pub const DestError = error{
    /// A Game Boy VRAM destination that is neither in the background character
    /// window nor in a tilemap. Refusing beats guessing: an unrecognised
    /// destination means the copy does something we have not modelled.
    UnmappedDestination,
    /// A character-window destination that does not start on a tile boundary.
    /// None exist in the retail ROM; a partial-tile copy would need a different
    /// converted representation and should be seen, not silently rounded.
    UnalignedDestination,
};

pub const Dest = union(enum) {
    /// A character index in BG3's 256-character window.
    chars: u16,
    /// A word index into a 32x32 tilemap.
    tilemap: u16,
    /// A word index into the window's map, BG2's (1.0 Step 6): what the
    /// Game Boy's $9C00 is while LCDC bit 6 selects it for the window, which
    /// every mode but the title's does. The Queen's head is its one door copy.
    window: u16,

    /// The absolute VRAM word address the converted copy writes to.
    ///
    /// Emitting this rather than the tagged pair is what lets a converted
    /// `COPY` operand go straight into $2116 with no dispatch on which region
    /// it names - the two regions are disjoint in VRAM, so the address is
    /// already the tag.
    pub fn wordAddr(self: Dest) u16 {
        return switch (self) {
            .chars => |c| bg3_char_base + c * charWords(play_depth),
            .tilemap => |w| bg3_map_base + w,
            .window => |w| bg2_map_base + w,
        };
    }
};

/// Where a Game Boy *object* VRAM destination lands, as an absolute word
/// address in the 4bpp object character region.
///
/// Objects address unsigned from `$8000`, so the tile index is just the
/// distance from the base. This exists as a second function rather than another
/// arm of `gbDestToChar` because the two answers are both correct for the same
/// input: `$8B00`-`$8FFF` is inside the background's signed window *and* inside
/// the object area, and the Game Boy lets one copy serve both. The SNES cannot
/// - BG3 is 2bpp and objects are always 4bpp - so a copy into the overlap
/// becomes two copies, one through each of these functions.
pub fn gbDestToObj(addr: u16) DestError!u16 {
    // Objects see $8000-$8FFF and nothing above it. $9000 is background-only,
    // which is exactly why `LOAD_bg` writes there.
    if (addr < gb_vram_base or addr >= gb_bg_signed_base) return DestError.UnmappedDestination;
    if (addr % 16 != 0) return DestError.UnalignedDestination;
    const index = (addr - gb_vram_base) / 16;
    return obj_char_base + index * charWords(obj_depth);
}

/// Is `addr` in the range the Game Boy shares between background and object
/// characters? A copy here has to be made twice.
pub fn inSharedWindow(addr: u16) bool {
    return addr >= gb_bg_window_lo and addr < gb_bg_signed_base;
}

/// Where a Game Boy VRAM destination address lands on the SNES.
pub fn gbDestToChar(addr: u16) DestError!Dest {
    if (addr >= gb_bg_window_lo and addr < gb_bg_window_hi) {
        if (addr % 16 != 0) return DestError.UnalignedDestination;
        // Undo the signed addressing: the window starts at id $80 and wraps.
        const index_in_window = (addr - gb_bg_window_lo) / 16;
        const id: u8 = @intCast((index_in_window + 0x80) % 0x100);
        return .{ .chars = charForTileId(id) };
    }
    if (addr >= gb_tilemap0_base and addr < gb_tilemap0_base + gb_tilemap_bytes) {
        return .{ .tilemap = addr - gb_tilemap0_base };
    }
    if (addr >= gb_tilemap1_base and addr < gb_tilemap1_base + gb_tilemap_bytes) {
        // Until 1.0 Step 6 both Game Boy tilemaps became the one BG3 tilemap,
        // which put the Queen's head over the top rows of her room. $9C00 is
        // the window's map (LCDC $E3, bit 6), and the window is BG2.
        return .{ .window = addr - gb_tilemap1_base };
    }
    return DestError.UnmappedDestination;
}

// ---- Tilemap words --------------------------------------------------------

/// A SNES background tilemap entry: `vhopppcc cccccccc`.
pub const TilemapWord = packed struct(u16) {
    char: u10,
    palette: u3,
    priority: u1,
    flip_h: bool,
    flip_v: bool,
};

/// Every converted play-field tile uses palette 0 at high priority and no flip.
///
/// The Game Boy has one background palette register and no per-tile attributes
/// at all, so there is nothing in the source to carry into these bits. They are
/// baked at conversion time rather than at runtime so that a later step which
/// wants per-area colour changes this file and re-runs the converter, instead
/// of adding an OR to the room loader's inner loop.
///
/// **The priority is 1 since Step 24e**, and not for anything in the source.
/// On some screens the Game Boy draws Samus behind the background's colours 1-3
/// (00:$3ED5, 01:$4BA1). In mode 1 an object can only go under BG3 if BG3's tile
/// has the priority bit: OBJ priority 0 sits between BG3's two levels. So every
/// play-field word has it, and the object's own priority decides. The engine's
/// `!PLAY_PRI` is the same bit for the words it writes itself.
pub const play_palette: u3 = 0;
pub const play_priority: u1 = 1;
/// The title's words keep priority 0: nothing is drawn behind it.
pub const title_priority: u1 = 0;

pub fn playWord(id: u8) TilemapWord {
    return .{
        .char = @intCast(charForTileId(id)),
        .palette = play_palette,
        .priority = play_priority,
        .flip_h = false,
        .flip_v = false,
    };
}

/// The character index a Game Boy background tile id becomes **on the title
/// screen**, which is a rotation by 128 rather than the identity.
///
/// The title is the one screen the game fills with a single copy: 4096 bytes
/// from `gfx_titleScreen` to $8800, which is 256 tiles laid down in VRAM
/// *address* order. Under the signed addressing the background uses, $8800 is
/// id $80 -- so the k'th tile of that copy is id `$80 + k`, and a converted
/// region that keeps the copy's order has id `n` at char `n - $80`.
///
/// Which is exactly the trade `charForTileId` describes and declines for the
/// play field: keep the id and let the destinations rotate, or keep the
/// destination and let the ids rotate. The play field has one copy per tileset
/// and a thousand metatiles, so it keeps the id. The title has one copy and one
/// tilemap, so it keeps the copy -- the engine lays four blobs down from char
/// zero and never has to split one across the wrap.
pub fn charForTitleId(id: u8) u16 {
    return id +% 0x80;
}

pub fn titleWord(id: u8) TilemapWord {
    return .{
        .char = @intCast(charForTitleId(id)),
        .palette = play_palette,
        .priority = title_priority,
        .flip_h = false,
        .flip_v = false,
    };
}

/// A window tile id as a BG2 word: character `id` among the objects' (BG2
/// reads them, `bg2_char_base`), palette 0, no priority, no flip. The
/// engine's `HudPut` writes the same word. Priority 0 because the Game Boy
/// draws every object over the window, and in mode 1 an object at priority 2
/// goes under a BG2 word that has the bit.
pub fn windowWord(id: u8) TilemapWord {
    return .{ .char = id, .palette = 0, .priority = 0, .flip_h = false, .flip_v = false };
}

pub fn windowIdFromWord(w: TilemapWord) ?u8 {
    if (w.palette != 0 or w.priority != 0 or w.flip_h or w.flip_v or w.char > 0xFF) return null;
    return @intCast(w.char);
}

/// The tile id a converted word came from, or null if the word carries bits the
/// converter never sets. Exists so the round-trip can close: recovering the id
/// from the word is what proves the extra bits are constant rather than
/// accidentally load-bearing.
pub fn tileIdFromWord(w: TilemapWord) ?u8 {
    if (w.palette != play_palette) return null;
    if (w.priority != play_priority) return null;
    if (w.flip_h or w.flip_v) return null;
    if (w.char > 0xFF) return null;
    return @intCast(w.char);
}

/// The same inversion for a word converted through `titleWord`. A separate
/// function rather than a flag because the two are different claims: this one
/// only closes if `charForTitleId` really is a bijection, which the test beside
/// it checks directly.
pub fn titleIdFromWord(w: TilemapWord) ?u8 {
    if (w.palette != play_palette) return null;
    if (w.priority != title_priority) return null;
    if (w.flip_h or w.flip_v) return null;
    if (w.char > 0xFF) return null;
    return @as(u8, @intCast(w.char)) -% 0x80;
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "the background window is exactly the span signed addressing reaches" {
    // id $80 sits at the bottom of the window and id $7F at the top. If either
    // end moved, `gbDestToChar`'s arithmetic would be addressing the wrong
    // bytes without any test noticing.
    try testing.expectEqual(@as(usize, gb_bg_window_lo - gb_vram_base), gbTileOffset(0x80));
    try testing.expectEqual(@as(usize, gb_bg_window_hi - gb_vram_base - 16), gbTileOffset(0x7F));
    try testing.expectEqual(@as(usize, gb_bg_signed_base - gb_vram_base), gbTileOffset(0x00));
    try testing.expectEqual(@as(usize, 0x8FF0 - gb_vram_base), gbTileOffset(0xFF));

    // And every id lands inside it, on a tile boundary, exactly once.
    var seen: [bg_chars]bool = @splat(false);
    for (0..256) |i| {
        const off = gbTileOffset(@intCast(i));
        try testing.expect(off >= gb_bg_window_lo - gb_vram_base);
        try testing.expect(off < gb_bg_window_hi - gb_vram_base);
        try testing.expectEqual(@as(usize, 0), off % 16);
        const slot = (off - (gb_bg_window_lo - gb_vram_base)) / 16;
        try testing.expect(!seen[slot]);
        seen[slot] = true;
    }
}

test "destination translation inverts the signed addressing for every tile" {
    // The property that matters: converting id -> Game Boy address -> character
    // must return the id. That is what makes the copy destinations and the
    // metatile words agree about which tile they mean.
    for (0..256) |i| {
        const id: u8 = @intCast(i);
        const addr: u16 = @intCast(gb_vram_base + gbTileOffset(id));
        const dest = try gbDestToChar(addr);
        try testing.expectEqual(Dest{ .chars = charForTileId(id) }, dest);
    }

    // The two destinations the retail door scripts actually use.
    try testing.expectEqual(Dest{ .chars = 0xB0 }, try gbDestToChar(0x8B00));
    try testing.expectEqual(Dest{ .chars = 0xF0 }, try gbDestToChar(0x8F00));
    try testing.expectEqual(Dest{ .chars = 0x00 }, try gbDestToChar(0x9000));

    // The background's map is BG3's and the window's BG2's (1.0 Step 6).
    try testing.expectEqual(Dest{ .tilemap = 0 }, try gbDestToChar(0x9800));
    try testing.expectEqual(Dest{ .window = 0 }, try gbDestToChar(0x9C00));
    try testing.expectEqual(Dest{ .window = 0x60 }, try gbDestToChar(0x9C60));
    try testing.expectEqual(bg2_map_base + 0x60, (try gbDestToChar(0x9C60)).wordAddr());
}

test "an unmodelled destination is refused rather than guessed at" {
    // $8000-$87FF is sprite-only: the background window does not reach it, so a
    // copy landing there is not something this converter can place.
    try testing.expectError(error.UnmappedDestination, gbDestToChar(0x8000));
    try testing.expectError(error.UnmappedDestination, gbDestToChar(0x87FF));
    try testing.expectError(error.UnmappedDestination, gbDestToChar(0xA000));
    try testing.expectError(error.UnalignedDestination, gbDestToChar(0x9008));
}

test "tilemap words round-trip through the id they were built from" {
    for (0..256) |i| {
        const id: u8 = @intCast(i);
        const w = playWord(id);
        try testing.expectEqual(@as(?u8, id), tileIdFromWord(w));
    }

    // The bit layout is the hardware's, not ours: char in the low ten bits,
    // then palette, priority, and the two flips. Getting this backwards would
    // still round-trip, so pin it against the raw value.
    const w: TilemapWord = .{ .char = 0x123, .palette = 5, .priority = 1, .flip_h = false, .flip_v = true };
    try testing.expectEqual(@as(u16, 0b1_0_1_101_0100100011), @as(u16, @bitCast(w)));

    // A word carrying anything the converter does not set is not ours.
    try testing.expectEqual(@as(?u8, null), tileIdFromWord(.{ .char = 1, .palette = 1, .priority = 0, .flip_h = false, .flip_v = false }));
    try testing.expectEqual(@as(?u8, null), tileIdFromWord(.{ .char = 1, .palette = 0, .priority = 0, .flip_h = true, .flip_v = false }));
    try testing.expectEqual(@as(?u8, null), tileIdFromWord(.{ .char = 0x300, .palette = 0, .priority = 0, .flip_h = false, .flip_v = false }));
}

test "every VRAM base honours the granularity its register imposes" {
    // Character bases: 4K words for backgrounds, 8K for objects.
    try testing.expectEqual(@as(u16, 0), bg3_char_base % 0x1000);
    try testing.expectEqual(@as(u16, 0), bg12_char_base % 0x1000);
    try testing.expectEqual(@as(u16, 0), obj_char_base % 0x2000);
    // Tilemap bases: 1K words.
    try testing.expectEqual(@as(u16, 0), bg3_map_base % 0x400);
    try testing.expectEqual(@as(u16, 0), bg2_map_base % 0x400);

    // And the regions must not overlap. BG3's characters are 256 tiles of 8
    // words; each tilemap is 32x32 words.
    const bg3_chars_end = bg3_char_base + bg_chars * charWords(play_depth);
    try testing.expect(bg3_chars_end <= bg3_map_base);
    try testing.expect(bg3_map_base + tilemap_words <= bg2_map_base);
    try testing.expect(bg2_map_base + tilemap_words <= bg12_char_base);
    try testing.expect(bg12_char_base < obj_char_base);
    try testing.expectEqual(@as(u16, 0), bg2_char_base % 0x1000);
    try testing.expect(obj_char_base < vram_words);
}

test "a copy destination becomes an absolute VRAM word address" {
    // The two regions are disjoint, which is what makes the address self-tagging.
    try testing.expectEqual(bg3_char_base, (Dest{ .chars = 0 }).wordAddr());
    try testing.expectEqual(bg3_char_base + 0x7F8, (Dest{ .chars = 0xFF }).wordAddr());
    try testing.expectEqual(bg3_map_base, (Dest{ .tilemap = 0 }).wordAddr());
    try testing.expectEqual(bg3_map_base + 0x3FF, (Dest{ .tilemap = 0x3FF }).wordAddr());
    try testing.expect((Dest{ .chars = 0xFF }).wordAddr() < (Dest{ .tilemap = 0 }).wordAddr());

    // The destinations the retail door scripts use, end to end.
    try testing.expectEqual(bg3_char_base + 0xB0 * 8, (try gbDestToChar(0x8B00)).wordAddr());
    try testing.expectEqual(bg3_char_base + 0xF0 * 8, (try gbDestToChar(0x8F00)).wordAddr());
    try testing.expectEqual(bg3_char_base, (try gbDestToChar(0x9000)).wordAddr());
    try testing.expectEqual(bg2_map_base + 0x60, (try gbDestToChar(0x9C60)).wordAddr());
}

test "the play window fits the SNES frame with the HUD band accounted for" {
    try testing.expect(view_w <= screen_w);
    try testing.expect(view_h <= screen_h);
    try testing.expectEqual(@as(u16, 8), hud_h);
    try testing.expectEqual(@as(usize, 2048), tilemap_bytes);
    try testing.expectEqual(@as(usize, 16), play_depth.bytesPerTile());
    try testing.expectEqual(@as(usize, 32), obj_depth.bytesPerTile());
}

test "the shared window has both answers, and they are different places" {
    // $8B00 is where LOAD_spr writes. It is tile id $B0 to the background and
    // tile index $B0 to objects - the same number, but 8 words per character
    // one side and 16 the other, in regions 24 KiB apart.
    try testing.expectEqual(bg3_char_base + 0xB0 * 8, (try gbDestToChar(0x8B00)).wordAddr());
    try testing.expectEqual(obj_char_base + 0xB0 * 16, try gbDestToObj(0x8B00));
    try testing.expect(inSharedWindow(0x8B00));
    try testing.expect(inSharedWindow(0x8FF0));
    // $8000 is objects only; $9000 is background only.
    try testing.expect(!inSharedWindow(0x8000));
    try testing.expect(!inSharedWindow(0x9000));
    try testing.expectEqual(obj_char_base, try gbDestToObj(0x8000));
    try testing.expectError(DestError.UnmappedDestination, gbDestToChar(0x8000));
    try testing.expectError(DestError.UnmappedDestination, gbDestToObj(0x9000));
    try testing.expectError(DestError.UnmappedDestination, gbDestToObj(0x9800));
    try testing.expectError(DestError.UnalignedDestination, gbDestToObj(0x8008));
    // Objects fill their region exactly: 256 characters of 16 words from the
    // base is the whole 8 KiB window OBSEL can name.
    try testing.expectEqual(obj_char_base + 0x1000, try gbDestToObj(0x8000) + 0x100 * 16);
}

test "the title's characters are the play field's, rotated by the one copy that loads them" {
    // The copy runs from $8800 to $97FF with no gap, so every id appears once
    // and the map is a bijection -- which is what says a converted title
    // tilemap can be inverted back to Game Boy ids by the round-trip.
    var seen: [256]bool = @splat(false);
    for (0..256) |i| {
        const id: u8 = @intCast(i);
        const char = charForTitleId(id);
        try testing.expect(char < 256);
        try testing.expect(!seen[char]);
        seen[char] = true;
    }
    // And the anchor the whole rotation rests on: the copy's first tile is the
    // id that lives at its destination.
    try testing.expectEqual(@as(usize, gb_bg_window_lo - gb_vram_base), gbTileOffset(0x80));
    try testing.expectEqual(@as(u16, 0), charForTitleId(0x80));
}
