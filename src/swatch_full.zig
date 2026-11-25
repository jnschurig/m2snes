//! The `full` scheme's swatch sheet (colorization Step 9): one HTML page with
//! every colour set's Mesen2 frame over its slots' shades, and the window,
//! object, suit and Metroid damage tables. `zig build swatch-full` takes the
//! frames and calls `writePage`; this file holds what the page says about
//! each set. ROM-free: the frames come in as PNG bytes.

const std = @import("std");
const areas = @import("areas.zig");
const colors = @import("colors.zig");
const screens = @import("screens.zig");
const full_slots = @import("full_slots.zig");
const png = @import("png");

/// A set's name on the sheet.
pub fn label(a: std.mem.Allocator, set: usize) ![]const u8 {
    const n = areas.Area.count;
    if (set < n) return areas.Area.label(@enumFromInt(set));
    if (set < n + n - 1) return std.fmt.allocPrint(a, "nest {s}", .{areas.Area.label(@enumFromInt(set - n))});
    if (set == areas.setOf(.acid)) return "acid";
    return "bubbles";
}

/// What each area's colours are after (James, 2026-11-22), in `areas.Area` order.
const area_notes = [areas.Area.count][]const u8{
    "Samus Returns' surface",
    "Samus Returns' area 1",
    "Samus Returns' area 2",
    "Chozo ruins: greens and browns",
    "Greys and blues, a little purple",
    "Greens and organics, red accents",
    "Browns and oranges",
    "The lab: greys and blues, green accents",
    "Dark teal caves, olive fronds",
    "Samus Returns' area 7: golden light",
    "Samus Returns' area 8: the nest",
    "Shades of green, like a nest",
};

fn setNote(a: std.mem.Allocator, set: usize) ![]const u8 {
    const n = areas.Area.count;
    if (set < n) return area_notes[set];
    if (set < n + n - 1) return std.fmt.allocPrint(a, "{s}, leaning green (Metroid rooms)", .{area_notes[set - n]});
    if (set == areas.setOf(.acid)) return "Acid caves: mostly purple (2.52.56, 2.43.02)";
    return "Super Metroid's Bubble Mountain, wherever the bubble tiles load";
}

/// Why a set may have no frame: what the warps found when they tried it.
fn missingNote(set: usize) []const u8 {
    if (set == areas.setOf(.{ .nest = .area7 })) return "No area 7 room has a Metroid, so the cart never shows this set.";
    if (set == areas.setOf(.{ .area = .area4 }) or set == areas.setOf(.{ .area = .area5 }))
        return "The rooms the warps reach draw with a lava table, so they show <b>acid</b>.";
    if (set == areas.setOf(.{ .area = .area8 }) or set == areas.setOf(.{ .area = .area9 }) or set == areas.setOf(.{ .nest = .area9 }))
        return "The rooms the warps reach load the bubble tiles, so they show <b>bubbles</b>.";
    return "No landing showed this set.";
}

const bg_slots = [colors.slot_count][]const u8{ "main rock", "spikes and coral (everywhere)", "second rock", "slowing liquid (everywhere)", "machinery", "acid (everywhere)", "structure", "plants" };
const queen_slots = [colors.slot_count][]const u8{ "main rock", "-", "second rock", "status bar fill", "machinery", "-", "structure", "floor, status bar glyphs" };
const obj_slots = [colors.slot_count][]const u8{ "shell: robots, Metroid shells", "Samus's suit (Power shown)", "the Queen", "frozen, flash", "Metroid body, green parts", "organic: most enemies", "beams, missiles, wave beam", "Samus's visor" };

/// The page: `frames[set]` is that set's PNG or null, `varia` Samus in the
/// Varia Suit or null.
pub fn writePage(a: std.mem.Allocator, w: *std.Io.Writer, frames: []const ?[]const u8, varia: ?[]const u8) !void {
    std.debug.assert(frames.len == areas.set_count);
    try w.writeAll("<title>Full Scheme Swatches</title>\n" ++ head);
    try w.print(
        \\<main>
        \\<header>
        \\<h1>Full scheme swatches</h1>
        \\<p class="lede">All {d} colour sets of the <code>full</code> scheme. Each frame is the debug cart in Mesen2, warped in <code>full</code> to a landing in that set. Each strip is one slot's shades 0-2, lightest first; shade 3 is black everywhere. Made by <code>zig build swatch-full</code>; the colours are <code>src/colors.zig</code>'s.</p>
        \\</header>
        \\
    , .{areas.set_count});
    try w.writeAll(notes);
    try w.writeAll("<section class=\"grid\">\n");
    for (colors.full.bg, frames, 0..) |set_slots, frame, s| {
        const lab = try label(a, s);
        try w.print("<article class=\"card\"><header><h3>{s}</h3><span class=\"set\">set {d}</span></header><p class=\"pair\">{s}</p><div class=\"shot\">", .{ lab, s, try setNote(a, s) });
        if (frame) |image| {
            try w.writeAll("<img src=\"data:image/png;base64,");
            try base64(w, image);
            try w.print("\" alt=\"Mesen2 frame, {s}\">", .{lab});
        } else try w.print("<div class=\"noshot\">{s}</div>", .{missingNote(s)});
        try w.writeAll("</div>");
        try tables(w, &set_slots, if (s == areas.setOf(.{ .area = .queen })) &queen_slots else &bg_slots);
        try w.writeAll("</article>\n");
    }
    try w.writeAll("</section>\n<section><h2>Global tables</h2><div class=\"global\">\n");
    try w.writeAll("<article class=\"card\"><h3>Sprites (OBJ palettes)</h3>");
    try tables(w, &colors.bases(colors.slot_count, colors.full.obj), &obj_slots);
    try w.writeAll("</article>\n<article class=\"card\"><h3>Samus's suits</h3>");
    if (varia) |image| {
        try w.writeAll("<div class=\"shot\"><img src=\"data:image/png;base64,");
        try base64(w, image);
        try w.writeAll("\" alt=\"Mesen2 frame, Samus in the Varia Suit\"></div><p class=\"pair\">The Varia Suit at the landing site (the debug menu's full loadout). The other frames show the Power Suit.</p>");
    }
    try tables(w, &colors.bases(4, colors.full.suits[0] ++ colors.full.suits[1]), &.{ "Power suit", "visor (both suits)", "Varia suit", "visor (both suits)" });
    try w.writeAll("</article>\n<article class=\"card\"><h3>Window (status bar, item names)</h3>");
    try tables(w, &colors.full.window, &.{ "palette 2", "palette 3", "palette 4", "palette 5" });
    try w.writeAll("</article>\n<article class=\"card\"><h3>Metroid damage (OBJ palette 2)</h3>");
    try tables(w, &colors.bases(colors.damage_steps - 1, colors.full.damage), &.{ "3/4 health", "1/2 health", "1/4 health" });
    try w.writeAll("</article>\n</div></section>\n</main>\n");
}

fn tables(w: *std.Io.Writer, ts: []const colors.Table, names: []const []const u8) !void {
    try w.writeAll("<ul class=\"slots\">");
    for (ts, names, 0..) |t, name, i| {
        try w.writeAll("<li><span class=\"sw\">");
        for (t[0..3], 0..) |c, k| {
            const hex = rgb(c);
            try w.print("<span style=\"background:#{x:0>6}\" title=\"shade {d}: #{x:0>6}\"></span>", .{ hex, k, hex });
        }
        try w.print("</span><span class=\"n\">{d}</span><span class=\"r\">{s}</span></li>", .{ i, name });
    }
    try w.writeAll("</ul>");
}

/// A BGR555 colour as 0xRRGGBB, each channel stretched to 8 bits.
fn rgb(c: u16) u24 {
    const r: u24 = (c & 31) * 255 / 31;
    const g: u24 = ((c >> 5) & 31) * 255 / 31;
    const b: u24 = ((c >> 10) & 31) * 255 / 31;
    return (r << 16) | (g << 8) | b;
}

fn base64(w: *std.Io.Writer, bytes: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    var buf: [4 * 256]u8 = undefined;
    var i: usize = 0;
    while (i < bytes.len) : (i += 3 * 256) {
        const chunk = bytes[i..@min(i + 3 * 256, bytes.len)];
        try w.writeAll(enc.encode(buf[0..enc.calcSize(chunk.len)], chunk));
    }
}

// ---- The enemy sheet ---------------------------------------------------------

/// A sprite sheet on the enemy page, drawn through `page` (and for Samus's
/// sheets, `suit`'s palettes).
pub const SheetSpec = struct { name: []const u8, title: []const u8, page: full_slots.ObjPage = .full, suit: u1 = 0 };

pub const enemy_sheets = [_]SheetSpec{
    .{ .name = "gfx_enemiesA", .title = "Enemies A" },
    .{ .name = "gfx_enemiesB", .title = "Enemies B" },
    .{ .name = "gfx_enemiesC", .title = "Enemies C" },
    .{ .name = "gfx_enemiesD", .title = "Enemies D" },
    .{ .name = "gfx_enemiesE", .title = "Enemies E" },
    .{ .name = "gfx_enemiesF", .title = "Enemies F" },
    .{ .name = "gfx_arachnus", .title = "Arachnus" },
    .{ .name = "gfx_metAlpha", .title = "Alpha Metroid" },
    .{ .name = "gfx_metGamma", .title = "Gamma Metroid" },
    .{ .name = "gfx_metZeta", .title = "Zeta Metroid" },
    .{ .name = "gfx_metOmega", .title = "Omega Metroid" },
    .{ .name = "gfx_queenSPR", .title = "The Queen" },
    .{ .name = "gfx_surfaceSPR", .title = "Surface sprites" },
    .{ .name = "gfx_items", .title = "Items" },
    .{ .name = "gfx_commonItems", .title = "Common items, drops" },
    .{ .name = "gfx_samusPowerSuit", .title = "Samus, Power Suit", .page = .samus, .suit = 0 },
    .{ .name = "gfx_samusVariaSuit", .title = "Samus, Varia Suit", .page = .samus, .suit = 1 },
};

/// The colours an object in OBJ palette `pal` shows, by Game Boy colour
/// index, through OBP0 `$93` as `colors.fullTable` loads them.
fn objColours(pal: u3, suit: u1) colors.Table16 {
    const t = if (pal == full_slots.samus_suit_palette)
        colors.full.suits[suit][0]
    else if (pal == full_slots.samus_visor_palette)
        colors.full.suits[suit][1]
    else
        colors.full.obj[pal];
    return colors.apply16(t, screens.live_obp0);
}

const sheet_cols = 16;
const sheet_scale = 3;
const sheet_ground: [3]u8 = .{ 0x22, 0x26, 0x2E };

/// Sheet `spec`'s Game Boy tiles (`gb`, 16 bytes each) as a PNG, sixteen to a
/// row as in VRAM, each in the palette the cart gives it (its slot through
/// `spec.page`, not flashing). Colour 0 is the ground, as it is transparent.
pub fn sheetPng(a: std.mem.Allocator, gb: []const u8, spec: SheetSpec) ![]u8 {
    const n = gb.len / 16;
    const rows = (n + sheet_cols - 1) / sheet_cols;
    const w = sheet_cols * 8 * sheet_scale;
    const h = rows * 8 * sheet_scale;
    var pal: std.ArrayList([3]u8) = .empty;
    try pal.append(a, sheet_ground);
    const px = try a.alloc(u8, w * h);
    @memset(px, 0);
    for (0..n) |t| {
        const s = full_slots.slot(spec.name, t) orelse 0;
        const p: u3 = @intCast((full_slots.objAttr(spec.page, s) >> 1) & 7);
        const cs = objColours(p, spec.suit);
        var idx: [4]u8 = .{ 0, 0, 0, 0 };
        for (1..4) |k| {
            const c = rgb(cs[k]);
            const v: [3]u8 = .{ @intCast(c >> 16), @intCast((c >> 8) & 0xFF), @intCast(c & 0xFF) };
            idx[k] = for (pal.items, 0..) |q, i| {
                if (std.mem.eql(u8, &q, &v)) break @intCast(i);
            } else blk: {
                try pal.append(a, v);
                break :blk @intCast(pal.items.len - 1);
            };
        }
        const tx = (t % sheet_cols) * 8;
        const ty = (t / sheet_cols) * 8;
        for (0..8) |r| {
            const lo = gb[t * 16 + r * 2];
            const hi = gb[t * 16 + r * 2 + 1];
            for (0..8) |x| {
                const b: u3 = @intCast(7 - x);
                const ci = ((hi >> b) & 1) << 1 | ((lo >> b) & 1);
                for (0..sheet_scale) |dy| for (0..sheet_scale) |dx| {
                    px[((ty + r) * sheet_scale + dy) * w + (tx + x) * sheet_scale + dx] = idx[ci];
                };
            }
        }
    }
    return png.encodeIndexed(a, px, w, h, pal.items);
}

// ---- Assembled sprites ------------------------------------------------------

/// A metasprite part as the ROM holds it (`entity.Part`): offsets from the
/// sprite's origin, the VRAM tile id, the Game Boy attribute.
pub const Part = struct { y: i8, x: i8, tile: u8, attr: u8 };

/// What the object tiles hold while a sprite is drawn: each VRAM tile id's
/// 16 bytes and slot, or null where the page loads nothing there.
pub const ObjVram = struct {
    tiles: [256]?*const [16]u8 = @splat(null),
    slots: [256]u3 = @splat(0),
};

/// One sprite, its parts put together as `PutObject` does (flips, and each
/// part's palette its tile's slot through `page` with the part's OBP1 bit),
/// as a PNG, or null when no part has a tile loaded.
pub fn spritePng(a: std.mem.Allocator, parts: []const Part, vram: *const ObjVram, page: full_slots.ObjPage, suit: u1) !?[]u8 {
    var x0: i32 = std.math.maxInt(i32);
    var y0: i32 = std.math.maxInt(i32);
    var x1: i32 = std.math.minInt(i32);
    var y1: i32 = std.math.minInt(i32);
    var any = false;
    for (parts) |q| {
        if (vram.tiles[q.tile] == null) continue;
        any = true;
        x0 = @min(x0, q.x);
        y0 = @min(y0, q.y);
        x1 = @max(x1, @as(i32, q.x) + 8);
        y1 = @max(y1, @as(i32, q.y) + 8);
    }
    if (!any) return null;
    const pad = 2;
    const sw: usize = @intCast(x1 - x0 + 2 * pad);
    const sh: usize = @intCast(y1 - y0 + 2 * pad);
    const w = sw * sheet_scale;
    const h = sh * sheet_scale;
    var pal: std.ArrayList([3]u8) = .empty;
    try pal.append(a, sheet_ground);
    const px = try a.alloc(u8, w * h);
    @memset(px, 0);
    // The Game Boy draws earlier OAM entries over later ones.
    var k = parts.len;
    while (k > 0) {
        k -= 1;
        const q = parts[k];
        const gb = vram.tiles[q.tile] orelse continue;
        const p: u3 = @intCast((full_slots.objAttr(page, (q.attr & 0xF0) | vram.slots[q.tile]) >> 1) & 7);
        const cs = objColours(p, suit);
        var idx: [4]u8 = .{ 0, 0, 0, 0 };
        for (1..4) |c| idx[c] = try paletteIndex(a, &pal, cs[c]);
        const ox: usize = @intCast(@as(i32, q.x) - x0 + pad);
        const oy: usize = @intCast(@as(i32, q.y) - y0 + pad);
        for (0..8) |r| for (0..8) |c| {
            const sr = if (q.attr & 0x40 != 0) 7 - r else r;
            const sc = if (q.attr & 0x20 != 0) 7 - c else c;
            const b: u3 = @intCast(7 - sc);
            const ci = ((gb[sr * 2 + 1] >> b) & 1) << 1 | ((gb[sr * 2] >> b) & 1);
            if (ci == 0) continue;
            for (0..sheet_scale) |dy| for (0..sheet_scale) |dx| {
                px[((oy + r) * sheet_scale + dy) * w + (ox + c) * sheet_scale + dx] = idx[ci];
            };
        };
    }
    return try png.encodeIndexed(a, px, w, h, pal.items);
}

/// How well a sprite's parts join with `vram` loaded: across each seam where
/// two parts touch (one 8 pixels right of or below the other), a pixel pair of
/// one colour scores 2, two colours 1, opaque against transparent -1; a part
/// whose tile is blank, -16. The sheet a sprite was drawn for scores highest.
pub fn coherence(parts: []const Part, vram: *const ObjVram) i32 {
    var score: i32 = 0;
    for (parts) |q| {
        const t = vram.tiles[q.tile] orelse continue;
        if (std.mem.allEqual(u8, t, 0)) score -= 16;
    }
    for (parts) |p| for (parts) |q| {
        const tp = vram.tiles[p.tile] orelse continue;
        const tq = vram.tiles[q.tile] orelse continue;
        const right = q.y == p.y and @as(i32, q.x) == @as(i32, p.x) + 8;
        const below = q.x == p.x and @as(i32, q.y) == @as(i32, p.y) + 8;
        if (!right and !below) continue;
        for (0..8) |i| {
            const ca = if (right) pixel(tp, p.attr, i, 7) else pixel(tp, p.attr, 7, i);
            const cb = if (right) pixel(tq, q.attr, i, 0) else pixel(tq, q.attr, 0, i);
            if (ca == 0 and cb == 0) continue;
            score += if (ca == 0 or cb == 0) -1 else if (ca == cb) 2 else 1;
        }
    };
    return score;
}

/// Pixel (`r`, `c`) of a part as drawn (flips applied): its colour index.
fn pixel(t: *const [16]u8, attr: u8, r: usize, c: usize) u2 {
    const sr = if (attr & 0x40 != 0) 7 - r else r;
    const sc = if (attr & 0x20 != 0) 7 - c else c;
    const b: u3 = @intCast(7 - sc);
    return @intCast(((t[sr * 2 + 1] >> b) & 1) << 1 | ((t[sr * 2] >> b) & 1));
}

fn paletteIndex(a: std.mem.Allocator, pal: *std.ArrayList([3]u8), c555: u16) !u8 {
    const c = rgb(c555);
    const v: [3]u8 = .{ @intCast(c >> 16), @intCast((c >> 8) & 0xFF), @intCast(c & 0xFF) };
    for (pal.items, 0..) |q, i| if (std.mem.eql(u8, &q, &v)) return @intCast(i);
    try pal.append(a, v);
    return @intCast(pal.items.len - 1);
}

/// The sheets an enemy can be drawn with (loaded at `$8B00` by a door).
pub fn isEnemySheet(name: []const u8) bool {
    for ([_][]const u8{ "gfx_enemies", "gfx_arachnus", "gfx_met", "gfx_surfaceSPR", "gfx_queenSPR" }) |pre| {
        if (std.mem.startsWith(u8, name, pre)) return true;
    }
    return false;
}

/// A group on the enemy page: the sprites drawn with one sheet loaded.
pub const SpriteGroup = struct {
    title: []const u8,
    note: []const u8,
    sprites: []const struct { id: u8, png: []const u8, spawns: usize, name: ?[]const u8 = null },
};

/// The enemy page: the assembled sprites by sheet, then `pngs[i]`, which
/// is `enemy_sheets[i]` from `sheetPng`.
pub fn writeEnemyPage(w: *std.Io.Writer, groups: []const SpriteGroup, pngs: []const []const u8) !void {
    std.debug.assert(pngs.len == enemy_sheets.len);
    try w.writeAll("<title>Full Scheme Enemy Swatches</title>\n" ++ head);
    try w.writeAll(
        \\<main>
        \\<header>
        \\<h1>Full scheme enemy swatches</h1>
        \\<p class="lede">Every sprite sheet of the <code>full</code> scheme, drawn from the ROM sixteen tiles to a row as they sit in VRAM, each tile in the palette the cart gives it. A multi-tile sprite's parts are usually neighbours. Made by <code>zig build swatch-full</code>; the colours are <code>src/colors.zig</code>'s, a tile's palette <code>src/full_assign.zig</code>'s slot through <code>full_slots.objAttr</code>.</p>
        \\</header>
        \\<section><h2>Notes</h2><ul class="notes">
        \\<li><b>Two enemy palettes:</b> "shell" (ivory to brown: the robots and the Metroids' shells) and "organic" (pinks and reds), with the Metroids' green for green parts. Which a part is drawn in is EJRTQ's slot for now; a part in the wrong one gets a hand choice.</li>
        \\<li><b>Samus's sheets</b> draw through her own page: her suit (the Varia Suit's shoulders too) and visor in her palettes.</li>
        \\<li><b>Assembled sprites</b> are the ROM's enemy sprite table. A spawned sprite and the frames after it are one enemy's animation, drawn with the sheet its parts join up best with, of those the doors can load into the rooms that spawn it; a few are pinned by hand where that walk can't tell (the Metroids, Arachnus). Parts on the Game Boy's second object palette take the cart's flash swap, as they do in play. The item orbs are left out.</li>
        \\<li><b>Names</b> come from the routine that runs each enemy (M2RoS's names), and where several species share one, by eye against the Metroid II enemy art: a name ending in "?" is a guess. Each animation's first sprite carries the name.</li>
        \\<li>Hit flashes and frozen enemies are not shown: frozen is palette 3 whole, the flash palette 3 or 6.</li>
        \\</ul></section>
        \\
    );
    for (groups) |g| {
        try w.print("<section><h2>{s}</h2><p class=\"pair\">{s}</p><div class=\"sprites\">", .{ g.title, g.note });
        for (g.sprites) |sp| {
            try w.writeAll("<figure><img class=\"sheet\" src=\"data:image/png;base64,");
            try base64(w, sp.png);
            try w.print("\" alt=\"sprite ${X:0>2}\"><figcaption>${X:0>2}{s}{s}</figcaption></figure>", .{ sp.id, sp.id, if (sp.name != null) " " else "", sp.name orelse "" });
        }
        try w.writeAll("</div></section>\n");
    }
    try w.writeAll("<section><h2>The sheets, as in VRAM</h2></section>\n<section class=\"global\">\n");
    for (enemy_sheets, pngs) |spec, p| {
        try w.print("<article class=\"card\"><header><h3>{s}</h3><span class=\"set\">{s}</span></header><div class=\"shot\"><img class=\"sheet\" src=\"data:image/png;base64,", .{ spec.title, spec.name });
        try base64(w, p);
        try w.print("\" alt=\"{s}, in the full scheme's colours\"></div></article>\n", .{spec.title});
    }
    try w.writeAll("</section>\n<section><h2>Sprite palettes</h2><div class=\"global\"><article class=\"card\">");
    try tables(w, &colors.bases(colors.slot_count, colors.full.obj), &obj_slots);
    try w.writeAll("</article></div></section>\n</main>\n");
}

const notes =
    \\<section><h2>Notes</h2><ul class="notes">
    \\<li><b>Spikes and coral, acid and the slowing liquid</b> are picked out by the ROM's collision bits and drawn red, purple and yellow in every area (slots 1, 5 and 3). Each tileset's other tiles share the five remaining slots.</li>
    \\<li><b>Which set a room shows:</b> the Queen's room, then the bubble tiles, then a Metroid room, then acid, then the area.</li>
    \\<li><b>Samus</b> has two palettes no other sprite uses: her suit, switched when she gets Varia, and her visor. The visor and the suit's red shading and outline are the same for both suits; the suit's main colour is yellow for Power and orange for Varia. Her helmet has no tiles of its own, so it can't be coloured apart from her body.</li>
    \\<li><b>The status bar</b> is light blue with black glyphs: the window's colour 3 must stay black. The Queen's head is drawn on the window layer, so it is the bar's blue.</li>
    \\</ul></section>
    \\
;

const head =
    \\<meta name="claude:viewport-fit-sides" content="cover">
    \\<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&family=Inter:wght@400;600&family=JetBrains+Mono:wght@400&display=swap">
    \\<style>
    \\/* Layout: a contact sheet of the cart's colour sets, each a Mesen frame over its 8 slot ramps */
    \\:root { --bg:#f3f4f7; --card:#ffffff; --fg:#16181f; --muted:#5b6070; --line:#d9dce5; --accent:#2f6fd8;
    \\  --display:"Space Grotesk",system-ui,sans-serif; --body:"Inter",system-ui,sans-serif; --mono:"JetBrains Mono",ui-monospace,monospace }
    \\@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#0f1116; --card:#181b22; --fg:#e8eaf0; --muted:#9aa0b0; --line:#2a2f3a; --accent:#6ea2ff; color-scheme:dark } }
    \\:root[data-theme="dark"] { --bg:#0f1116; --card:#181b22; --fg:#e8eaf0; --muted:#9aa0b0; --line:#2a2f3a; --accent:#6ea2ff; color-scheme:dark }
    \\body { background:var(--bg); color:var(--fg); font-family:var(--body); line-height:1.5;
    \\  padding-left:max(16px,env(safe-area-inset-left,0px)); padding-right:max(16px,env(safe-area-inset-right,0px)); padding-block:24px 48px }
    \\main { max-width:1280px; margin:0 auto; display:grid; gap:28px }
    \\h1,h2,h3 { font-family:var(--display); text-wrap:balance; margin:0 }
    \\h1 { font-size:1.9rem } h2 { font-size:1.25rem } h3 { font-size:1.05rem; text-transform:capitalize }
    \\.lede { max-width:68ch; color:var(--muted); margin:6px 0 0 }
    \\.notes { max-width:75ch; margin:0; padding-left:1.2em; display:grid; gap:6px }
    \\.grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(290px,1fr)); gap:16px }
    \\.card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px; display:grid; gap:10px; align-content:start; min-width:0 }
    \\.card header { display:flex; justify-content:space-between; align-items:baseline; gap:8px }
    \\.set { font-family:var(--mono); font-size:.75rem; color:var(--muted); font-variant-numeric:tabular-nums }
    \\.pair { margin:0; font-size:.85rem; color:var(--muted) }
    \\.shot img { width:100%; image-rendering:pixelated; display:block; border-radius:4px; background:#000 }
    \\.noshot { aspect-ratio:256/224; max-width:100%; display:grid; place-items:center; text-align:center; padding:16px; font-size:.85rem; color:var(--muted); border:1px dashed var(--line); border-radius:4px }
    \\.slots { list-style:none; margin:0; padding:0; display:grid; gap:4px }
    \\.slots li { display:grid; grid-template-columns:72px 16px 1fr; gap:8px; align-items:center; font-size:.78rem }
    \\.sw { display:flex; height:16px; border-radius:3px; overflow:hidden; outline:1px solid var(--line) }
    \\.sw span { flex:1 }
    \\.n { font-family:var(--mono); color:var(--muted); text-align:right }
    \\.r { min-width:0 }
    \\.global { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:16px }
    \\.shot img.sheet { background:#22262e; width:auto; max-width:100% }
    \\.sprites { display:flex; flex-wrap:wrap; gap:10px; align-items:flex-end }
    \\.sprites figure { margin:0; display:grid; gap:2px; justify-items:center }
    \\.sprites img { background:#22262e; border-radius:4px; image-rendering:pixelated; max-width:100% }
    \\.sprites figcaption { font-family:var(--mono); font-size:.7rem; color:var(--muted) }
    \\</style>
    \\
;

const testing = std.testing;

test "the swatch page: a card per set, a frame where there is one, and the note where not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var frames: [areas.set_count]?[]const u8 = @splat(null);
    frames[0] = "PNG";
    var out: std.Io.Writer.Allocating = .init(a);
    try writePage(a, &out.writer, &frames, null);
    const page = out.written();
    try testing.expect(std.mem.startsWith(u8, page, "<title>Full Scheme Swatches</title>"));
    try testing.expectEqual(@as(usize, areas.set_count), std.mem.count(u8, page, "<article class=\"card\"><header>"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, page, "data:image/png;base64,UE5H\""));
    try testing.expect(std.mem.indexOf(u8, page, missingNote(areas.setOf(.{ .nest = .area7 }))) != null);
    // Every set's colours, shade 0, as the page writes it.
    for (colors.full.bg) |set_slots| {
        const want = try std.fmt.allocPrint(a, "#{x:0>6}", .{rgb(set_slots[0][0])});
        try testing.expect(std.mem.indexOf(u8, page, want) != null);
    }
}

test "rgb stretches each 5-bit channel to 8 bits" {
    try testing.expectEqual(@as(u24, 0xFF0000), rgb(0x001F));
    try testing.expectEqual(@as(u24, 0x00FF00), rgb(0x03E0));
    try testing.expectEqual(@as(u24, 0x0000FF), rgb(0x7C00));
}

test "a sprite's parts go where their offsets say, flipped as their attributes say" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A tile whose top-left pixel alone is set (colour 1).
    var t: [16]u8 = @splat(0);
    t[0] = 0x80;
    var v: ObjVram = .{};
    v.tiles[0xB0] = &t;
    // Two parts side by side, the second flipped both ways: its set pixel is
    // its bottom-right.
    const parts = [_]Part{ .{ .y = 0, .x = 0, .tile = 0xB0, .attr = 0 }, .{ .y = 0, .x = 8, .tile = 0xB0, .attr = 0x60 } };
    const out = (try spritePng(a, &parts, &v, .full, 0)).?;
    const d = try png.decodeIndexed(a, out);
    try testing.expectEqual(@as(usize, (16 + 4) * sheet_scale), d.w);
    const at = struct {
        fn f(dd: png.Decoded, x: usize, y: usize) u8 {
            return dd.pixels[(y * sheet_scale) * dd.w + x * sheet_scale];
        }
    }.f;
    try testing.expect(at(d, 2, 2) != 0);
    try testing.expect(at(d, 2 + 15, 2 + 7) != 0);
    try testing.expectEqual(@as(u8, 0), at(d, 2 + 8, 2));
    // Nothing loaded: no picture.
    const none_parts = [_]Part{.{ .y = 0, .x = 0, .tile = 0x10, .attr = 0 }};
    try testing.expect((try spritePng(a, &none_parts, &v, .full, 0)) == null);
}

test "coherence: parts whose edges meet beat parts whose edges don't" {
    // A tile solid on its right column, one solid on its left, one blank.
    var r: [16]u8 = @splat(0);
    var l: [16]u8 = @splat(0);
    for (0..8) |i| {
        r[i * 2] = 0x01;
        l[i * 2] = 0x80;
    }
    const blank: [16]u8 = @splat(0);
    var good: ObjVram = .{};
    good.tiles[0xB0] = &r;
    good.tiles[0xB1] = &l;
    var bad: ObjVram = .{};
    bad.tiles[0xB0] = &r;
    bad.tiles[0xB1] = &blank;
    const parts = [_]Part{ .{ .y = 0, .x = 0, .tile = 0xB0, .attr = 0 }, .{ .y = 0, .x = 8, .tile = 0xB1, .attr = 0 } };
    try testing.expectEqual(@as(i32, 16), coherence(&parts, &good));
    try testing.expectEqual(@as(i32, -16 - 8), coherence(&parts, &bad));
}

test "a sheet renders a tile per 16 bytes, sixteen to a row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var gb: [17 * 16]u8 = @splat(0xFF);
    const out = try sheetPng(a, &gb, enemy_sheets[0]);
    const d = try png.decodeIndexed(a, out);
    try testing.expectEqual(@as(usize, sheet_cols * 8 * sheet_scale), d.w);
    try testing.expectEqual(@as(usize, 2 * 8 * sheet_scale), d.h);
}
