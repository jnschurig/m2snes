//! The `full` scheme's colour areas: which area every map screen is in.
//!
//! An area is a function of the map bank and the screen (the camera's cell),
//! which is all the cart needs to know. The Queen's room is an area of its own.
//!
//! The areas are those of `metroid-2-areas.gif` (the surface and areas 1-10).
//! Each boundary sits where the GIF puts it: at the acid that drains when the
//! area's Metroids are cleared. The shaft below a gate belongs to the area it
//! leads into.
//!
//! This file holds one **seed** per room, and **cuts** where a gate falls
//! inside a room. `fill` spreads each seed over its room: two cells are linked
//! when the camera can scroll from one to the other (the ROM's scroll flags,
//! `roster.World.room`). Doors are not followed. The crawl walks every door
//! with every item at every Metroid count, so its door graph joins areas at
//! every late-game shortcut, and cutting each would hide the real boundaries
//! among dozens. A room with no seed, a room two seeds disagree on with no cut
//! between them, and a cut that matches no link are errors.
//!
//! `zig build areas -- draft` writes a first draft of the seeds from the 100%
//! recording: each room takes the area whose gate the Metroid count was past
//! when the run first reached it. The rooms it can't settle were then placed
//! by hand against the GIF; the comments say which.
//!
//! The table `fill` produces follows the ROM's scroll flags, so it is built
//! into the cart at build time and never committed.

const std = @import("std");
const map = @import("map.zig");
const roster = @import("roster.zig");

pub const Area = enum(u8) {
    surface,
    area1,
    area2,
    area3,
    area4,
    area5,
    area6,
    area7,
    area8,
    area9,
    area10,
    queen,

    pub const count = @typeInfo(Area).@"enum".fields.len;

    pub fn label(self: Area) []const u8 {
        return switch (self) {
            .surface => "surface",
            .queen => "queen",
            inline else => |a| "area " ++ @tagName(a)["area".len..],
        };
    }
};

pub const Place = roster.Place;
pub const Dir = roster.Dir;

pub const Seed = struct { at: Place, area: Area };

/// A link that no area spreads across: the pair `{a, b}`, in either order.
pub const Cut = struct { a: Place, b: Place };

fn p(bank: u8, cell: u8) Place {
    return .{ .bank = bank, .cell = cell };
}

/// The cut between a cell and its neighbour one screen over.
fn edge(bank: u8, cell: u8, dir: Dir) Cut {
    return .{ .a = p(bank, cell), .b = p(bank, dir.step(cell).?) };
}

// ---- The data ---------------------------------------------------------------

fn s(bank: u8, cell: u8, area: Area) Seed {
    return .{ .at = p(bank, cell), .area = area };
}

/// One seed per room, at the cell the recording reached first (or the room's
/// first cell). "first at" is the real Metroid count then; "unvisited" rooms
/// take a neighbour's area. Below each in-room gate (`cuts`) a second seed.
pub const seeds = [_]Seed{
    s(0x9, 0x84, .area6), // room 0, 44 cells, first at 20
    s(0x9, 0x3C, .area2), // room 1, 45 cells, first at 41
    s(0x9, 0x6A, .area3), // room 2, 30 cells, first at 34
    s(0x9, 0xDE, .area1), // room 3, 32 cells, first at 46
    s(0xA, 0x00, .area1), // room 4, 6 cells, first at 46
    s(0xA, 0x05, .area5), // room 5, 1 cells; unvisited, no doors; beside $A:06
    s(0xA, 0x16, .area5), // room 6, 3 cells, first at 22
    s(0xA, 0x08, .area1), // room 7, 12 cells, first at 46
    s(0xA, 0x22, .area2), // room 8, 6 cells, first at 42
    s(0xA, 0x26, .area5), // room 9, 4 cells, first at 23
    s(0xA, 0x40, .area3), // room 10, 6 cells, first at 34
    s(0xA, 0x44, .surface), // room 11, 5 cells, first at 47
    s(0xA, 0x54, .area2), // room 12, 8 cells, first at 42
    s(0xA, 0x5B, .area3), // room 13, 1 cells; unvisited, no doors
    s(0xA, 0x63, .area3), // room 14, 1 cells; unvisited; door to $A:64
    s(0xA, 0x66, .area6), // room 15, 10 cells, first at 21
    s(0xA, 0x68, .area8), // room 16, 4 cells, first at 12
    s(0xA, 0x81, .area4), // room 17, 14 cells, first at 24
    s(0xA, 0x83, .area3), // room 18, 14 cells, first at 34
    s(0xA, 0x98, .area10), // room 19, 2 cells, first at 9
    s(0xA, 0x9B, .area10), // room 20, 4 cells, first at 9
    s(0xA, 0xAC, .area10), // room 21, 1 cells; unvisited; door to $A:CB
    s(0xA, 0xAD, .area10), // room 22, 1 cells; unvisited; door to $A:CC
    s(0xA, 0xB4, .area7), // room 23, 4 cells, first at 13
    s(0xA, 0xB9, .area10), // room 24, 5 cells, first at 9
    s(0xA, 0xC7, .area7), // room 25, 6 cells, first at 14
    s(0xA, 0xC9, .area10), // room 26, 6 cells, first at 9
    s(0xA, 0xF4, .area6), // room 27, 2 cells, first at 17
    s(0xA, 0xF8, .area6), // room 28, 2 cells, first at 19
    s(0xB, 0x01, .area6), // room 29, 2 cells, first at 16
    s(0xB, 0x04, .area6), // room 30, 2 cells, first at 15
    s(0xB, 0x0D, .area1), // room 31, 2 cells, first at 46
    s(0xB, 0x13, .area1), // room 32, 3 cells, first at 46
    s(0xB, 0x16, .area1), // room 33, 3 cells, first at 46
    s(0xB, 0x1B, .area1), // room 34, 4 cells, first at 45
    s(0xB, 0x22, .area2), // room 35, 3 cells, first at 42
    s(0xB, 0x24, .area2), // room 36, 2 cells, first at 42
    s(0xB, 0x27, .area3), // room 37, 1 cells, first at 34
    s(0xB, 0x28, .area3), // room 38, 3 cells, first at 34
    s(0xB, 0x2B, .area4), // room 39, 2 cells, first at 24
    s(0xB, 0x2D, .area3), // room 40, 2 cells, first at 25
    s(0xB, 0x31, .area3), // room 41, 4 cells; unvisited; doors to areas 3, 4 and 6
    s(0xB, 0x35, .area3), // room 42, 2 cells; unvisited; doors to $C:38 and $C:47
    s(0xB, 0x38, .area3), // room 43, 3 cells, first at 28
    s(0xB, 0x3B, .area3), // room 44, 1 cells, first at 27
    s(0xB, 0x40, .area4), // room 45, 4 cells, first at 24
    s(0xB, 0x44, .area4), // room 46, 2 cells, first at 24
    s(0xB, 0x49, .area6), // room 47, 4 cells, first at 16
    s(0xB, 0x4D, .area6), // room 48, 2 cells, first at 17
    s(0xB, 0x51, .area6), // room 49, 4 cells, first at 21
    s(0xB, 0x59, .area6), // room 50, 4 cells, first at 19
    s(0xB, 0x62, .area7), // room 51, 2 cells, first at 14
    s(0xB, 0x66, .area8), // room 52, 5 cells, first at 14; Alpha (hatching), kill 34
    s(0xB, 0x75, .area9), // room 53, 2 cells, first at 11; Omega, kill 37
    s(0xB, 0x80, .area10), // room 54, 1 cells, first at 9
    s(0xB, 0x89, .area8), // room 55, 2 cells; unvisited; door to $B:8B
    s(0xB, 0x8D, .area8), // room 56, 5 cells, first at 13; Omega, kill 35
    s(0xB, 0x97, .area8), // room 57, 4 cells, first at 12
    s(0xB, 0x9B, .area7), // room 58, 2 cells, first at 14
    s(0xB, 0x9E, .area7), // room 59, 2 cells, first at 13
    s(0xB, 0xA1, .area1), // room 60, 2 cells, first at 46
    s(0xB, 0xA7, .area3), // room 61, 3 cells, first at 30; backtracked at 24
    s(0xB, 0xB9, .area1), // room 62, 2 cells, first at 45
    s(0xB, 0xAB, .area3), // room 63, 2 cells, first at 29
    s(0xB, 0xAD, .area3), // room 64, 2 cells, first at 26
    s(0xB, 0xB1, .area3), // room 65, 3 cells; unvisited; beside $B:B4
    s(0xB, 0xB4, .area3), // room 66, 3 cells; unvisited; door to $B:A6
    s(0xB, 0xC8, .area1), // room 67, 2 cells, first at 43
    s(0xB, 0xBA, .area1), // room 68, 3 cells, first at 45
    s(0xB, 0xBD, .area1), // room 69, 2 cells, first at 45
    s(0xB, 0xC0, .area7), // room 70, 4 cells, first at 14
    s(0xB, 0xC4, .area1), // room 71, 1 cells, first at 43
    s(0xB, 0xC5, .area1), // room 72, 3 cells, first at 43
    s(0xB, 0xC9, .area1), // room 73, 2 cells, first at 44
    s(0xB, 0xDB, .area2), // room 74, 2 cells, first at 38
    s(0xB, 0xCE, .area3), // room 75, 3 cells, first at 30; backtracked at 21
    s(0xB, 0xD0, .area6), // room 76, 2 cells, first at 15
    s(0xB, 0xE7, .area2), // room 77, 2 cells, first at 35
    s(0xB, 0xDA, .area2), // room 78, 3 cells, first at 37
    s(0xB, 0xDC, .area2), // room 79, 2 cells, first at 38
    s(0xB, 0xDE, .area2), // room 80, 2 cells, first at 38
    s(0xB, 0xE3, .area3), // room 81, 1 cells, first at 34
    s(0xB, 0xE4, .area2), // room 82, 3 cells, first at 35
    s(0xB, 0xE8, .area2), // room 83, 2 cells, first at 36
    s(0xB, 0xEA, .area2), // room 84, 4 cells, first at 36
    s(0xB, 0xEE, .area2), // room 85, 2 cells; unvisited; door to $B:ED
    s(0xB, 0xF1, .area5), // room 86, 4 cells, first at 22
    s(0xB, 0xF5, .area5), // room 87, 4 cells, first at 23
    s(0xB, 0xF9, .area4), // room 88, 7 cells, first at 24
    s(0xC, 0x02, .area1), // room 89, 3 cells, first at 46
    s(0xC, 0x03, .area1), // room 90, 2 cells, first at 46
    s(0xC, 0x04, .area3), // room 91, 2 cells, first at 34
    s(0xC, 0x05, .area3), // room 92, 1 cells, first at 34
    s(0xC, 0x06, .area3), // room 93, 4 cells, first at 28
    s(0xC, 0x08, .area3), // room 94, 4 cells, first at 34
    s(0xC, 0x09, .area3), // room 95, 1 cells; unvisited, no doors; beside $C:08
    s(0xC, 0x0A, .area6), // room 96, 1 cells, first at 21
    s(0xC, 0x3C, .area8), // room 97, 5 cells, first at 11
    s(0xC, 0x0D, .area7), // room 98, 2 cells, first at 13
    s(0xC, 0x0E, .area8), // room 99, 2 cells; unvisited; doors to $B:8B and $A:68
    s(0xC, 0x17, .area2), // room 100, 2 cells; unvisited; door to $D:A7
    s(0xC, 0x19, .area3), // room 101, 7 cells, first at 26
    s(0xC, 0x21, .surface), // room 102, 3 cells, first at 47
    s(0xC, 0x25, .area3), // room 103, 1 cells, first at 34
    s(0xC, 0x57, .area3), // room 104, 4 cells, first at 25
    s(0xC, 0x3A, .area6), // room 105, 1 cells, first at 21
    s(0xC, 0x43, .area3), // room 106, 1 cells; unvisited, no doors; beside $C:45
    s(0xC, 0x45, .area3), // room 107, 1 cells, first at 34
    s(0xC, 0x46, .area5), // room 108, 3 cells, first at 23
    s(0xC, 0x78, .area3), // room 109, 6 cells, first at 26
    s(0xC, 0x4A, .area4), // room 110, 3 cells, first at 24
    s(0xC, 0x4D, .area8), // room 111, 3 cells, first at 11
    s(0xC, 0x51, .surface), // room 112, 4 cells, first at 47
    s(0xC, 0x54, .area5), // room 113, 3 cells, first at 22
    s(0xC, 0x55, .area2), // room 114, 1 cells, first at 42
    s(0xC, 0x5C, .area8), // room 115, 1 cells; unvisited; door to $C:5D
    s(0xC, 0x63, .area5), // room 116, 1 cells; unvisited, no doors; beside $C:54
    s(0xC, 0x6C, .area8), // room 117, 7 cells, first at 12
    s(0xC, 0x76, .area7), // room 118, 2 cells, first at 13
    s(0xC, 0x7A, .area7), // room 119, 2 cells, first at 14
    s(0xC, 0x80, .area10), // room 120, 6 cells; unvisited; door to $A:CE
    s(0xC, 0x83, .area10), // room 121, 1 cells; unvisited; door to $C:84
    s(0xC, 0x84, .area10), // room 122, 4 cells, first at 9
    s(0xC, 0x85, .area2), // room 123, 1 cells, first at 42
    s(0xC, 0x87, .area7), // room 124, 2 cells, first at 13
    s(0xC, 0x89, .area7), // room 125, 1 cells; unvisited, no doors; beside $C:8B
    s(0xC, 0x8B, .area7), // room 126, 2 cells, first at 14
    s(0xC, 0x8D, .area10), // room 127, 1 cells; unvisited, no doors; beside $C:8F
    s(0xC, 0x8F, .area10), // room 128, 6 cells, first at 9
    s(0xC, 0x91, .area1), // room 129, 1 cells; unvisited, no doors; beside $C:A1
    s(0xC, 0x99, .area5), // room 130, 6 cells, first at 23
    s(0xC, 0x9A, .area8), // room 131, 4 cells, first at 12
    s(0xC, 0x9D, .area8), // room 132, 3 cells, first at 12
    s(0xC, 0xA1, .area1), // room 133, 2 cells, first at 46
    s(0xC, 0xA2, .area2), // room 134, 5 cells, first at 39
    s(0xC, 0xA3, .area3), // room 135, 5 cells, first at 30
    s(0xC, 0xA6, .area7), // room 136, 5 cells, first at 14
    s(0xC, 0xAB, .area8), // room 137, 5 cells, first at 12
    s(0xC, 0xB7, .area10), // room 138, 2 cells, first at 9
    s(0xC, 0xC1, .area1), // room 139, 1 cells, first at 46
    s(0xC, 0xC8, .area10), // room 140, 2 cells, first at 9
    s(0xC, 0xCD, .area8), // room 141, 1 cells; unvisited, no doors; beside $C:DD
    s(0xC, 0xDD, .area8), // room 142, 3 cells, first at 12
    s(0xC, 0xE1, .area1), // room 143, 1 cells, first at 46
    s(0xC, 0xE8, .area10), // room 144, 2 cells, first at 9
    s(0xD, 0x00, .area10), // room 145, 2 cells, first at 3
    s(0xD, 0x05, .area2), // room 146, 2 cells, first at 39
    s(0xD, 0x11, .area10), // room 147, 2 cells, first at 9
    s(0xD, 0x13, .area10), // room 148, 1 cells, first at 5
    s(0xD, 0x18, .area1), // room 149, 3 cells, first at 45
    s(0xD, 0x2B, .area1), // room 150, 5 cells, first at 46
    s(0xD, 0x20, .area10), // room 151, 2 cells, first at 9
    s(0xD, 0x26, .area1), // room 152, 4 cells, first at 46
    s(0xD, 0x31, .area10), // room 153, 2 cells, first at 9
    s(0xD, 0x42, .area10), // room 154, 2 cells, first at 8
    s(0xD, 0x33, .area10), // room 155, 1 cells, first at 7
    s(0xD, 0x38, .area1), // room 156, 3 cells, first at 46
    s(0xD, 0x40, .area10), // room 157, 2 cells; unvisited; doors to $D:20 and $F:BC
    s(0xD, 0x44, .area1), // room 158, 1 cells, first at 46
    s(0xD, 0x45, .area1), // room 159, 2 cells, first at 46
    s(0xD, 0x4C, .area1), // room 160, 3 cells, first at 46
    s(0xD, 0x51, .area2), // room 161, 2 cells, first at 41
    s(0xD, 0x53, .area2), // room 162, 3 cells, first at 41
    s(0xD, 0x56, .area2), // room 163, 2 cells, first at 41
    s(0xD, 0x58, .area1), // room 164, 1 cells, first at 46
    s(0xD, 0x59, .area1), // room 165, 2 cells, first at 46
    s(0xD, 0x60, .area2), // room 166, 2 cells, first at 40
    s(0xD, 0x62, .area2), // room 167, 1 cells, first at 40
    s(0xD, 0x63, .area2), // room 168, 3 cells, first at 40
    s(0xD, 0x75, .area2), // room 169, 2 cells, first at 40
    s(0xD, 0x77, .area2), // room 170, 3 cells, first at 39
    s(0xD, 0x79, .area2), // room 171, 1 cells, first at 41
    s(0xD, 0x90, .area2), // room 172, 2 cells, first at 41
    s(0xD, 0x91, .area2), // room 173, 3 cells, first at 41
    s(0xD, 0xA4, .area2), // room 174, 1 cells, first at 39
    s(0xD, 0xA5, .area2), // room 175, 4 cells, first at 39
    s(0xD, 0xA9, .area2), // room 176, 3 cells, first at 39
    s(0xD, 0xBA, .area2), // room 177, 3 cells, first at 39
    s(0xD, 0xC0, .area2), // room 178, 1 cells, first at 40
    s(0xD, 0xC1, .area2), // room 179, 2 cells, first at 40
    s(0xD, 0xC5, .area2), // room 180, 2 cells, first at 39
    s(0xD, 0xC6, .area2), // room 181, 3 cells, first at 39
    s(0xD, 0xD6, .area2), // room 182, 3 cells, first at 39
    s(0xD, 0xD9, .area2), // room 183, 1 cells, first at 39
    s(0xE, 0x04, .area10), // room 184, 5 cells, first at 4
    s(0xE, 0x07, .area1), // room 185, 1 cells, first at 46
    s(0xE, 0x08, .area6), // room 186, 1 cells, first at 19
    s(0xE, 0x11, .area10), // room 187, 3 cells, first at 1
    s(0xE, 0x1A, .area6), // room 188, 2 cells, first at 17
    s(0xE, 0x21, .area10), // room 189, 2 cells, first at 9
    s(0xE, 0x2A, .area6), // room 190, 2 cells, first at 17
    s(0xE, 0x32, .area10), // room 191, 3 cells, first at 9
    s(0xE, 0x3A, .area6), // room 192, 2 cells, first at 18
    s(0xE, 0x4A, .area7), // room 193, 2 cells, first at 14
    s(0xE, 0x54, .area3), // room 194, 2 cells, first at 33
    s(0xE, 0x5A, .area7), // room 195, 1 cells, first at 14
    s(0xE, 0x5B, .area7), // room 196, 4 cells, first at 14
    s(0xE, 0x61, .area3), // room 197, 2 cells, first at 34
    s(0xE, 0x64, .area3), // room 198, 3 cells, first at 33
    s(0xE, 0x65, .area3), // room 199, 1 cells, first at 34
    s(0xE, 0x6A, .area7), // room 200, 1 cells, first at 14
    s(0xE, 0x75, .area3), // room 201, 3 cells, first at 33
    s(0xE, 0x7A, .area7), // room 202, 1 cells, first at 14
    s(0xE, 0x81, .area3), // room 203, 1 cells, first at 33
    s(0xE, 0x82, .area3), // room 204, 2 cells, first at 33
    s(0xE, 0x8A, .area7), // room 205, 1 cells, first at 14
    s(0xE, 0x98, .area3), // room 206, 2 cells, first at 31
    s(0xE, 0x9A, .area7), // room 207, 2 cells, first at 14
    s(0xE, 0xA0, .area3), // room 208, 1 cells, first at 31
    s(0xE, 0xA1, .area3), // room 209, 2 cells, first at 31
    s(0xE, 0xA3, .area3), // room 210, 2 cells, first at 32
    s(0xE, 0xA5, .area3), // room 211, 3 cells, first at 32
    s(0xE, 0xAA, .area7), // room 212, 4 cells, first at 14
    s(0xE, 0xB0, .area3), // room 213, 2 cells, first at 30
    s(0xE, 0xB3, .area3), // room 214, 3 cells, first at 31
    s(0xE, 0xB5, .area3), // room 215, 3 cells, first at 31
    s(0xE, 0xD1, .area10), // room 216, 1 cells, first at 9
    s(0xF, 0x00, .surface), // room 217, 2 cells, first at 47
    s(0xF, 0x02, .surface), // room 218, 4 cells, first at 47
    s(0xF, 0x1A, .surface), // room 219, 50 cells, first at 0
    s(0xF, 0x10, .surface), // room 220, 2 cells, first at 47
    s(0xF, 0x12, .surface), // room 221, 4 cells, first at 47
    s(0xF, 0x20, .surface), // room 222, 30 cells; unvisited: the landing site's unused west half
    s(0xF, 0x76, .surface), // room 223, 9 cells, first at 47
    s(0xF, 0x58, .surface), // room 224, 1 cells; unvisited
    s(0xF, 0x5A, .surface), // room 225, 1 cells; unvisited
    s(0xF, 0x6A, .surface), // room 226, 3 cells, first at 47
    s(0xF, 0xA9, .area10), // room 227, 1 cells; unvisited: `EXIT_QUEEN`'s cell, on the GIF's area 10 exit
    s(0xF, 0xAA, .area10), // room 228, 1 cells; unvisited; doors to $F:A9 and $F:CA
    s(0xF, 0xAE, .area10), // room 229, 1 cells; unvisited, no doors; beside $F:BE
    s(0xF, 0xB0, .area9), // room 230, 2 cells, first at 10
    s(0xF, 0xB2, .area9), // room 231, 4 cells, first at 10
    s(0xF, 0xBB, .area10), // room 232, 22 cells, first at 9
    s(0xF, 0xC0, .area9), // room 233, 4 cells, first at 11; Omega corridors (ROM tour)
    s(0xF, 0xD0, .area9), // room 234, 4 cells, first at 11; Omega corridors (ROM tour)
    s(0xF, 0xE0, .area9), // room 235, 2 cells, first at 12; Omega, kill 36
    s(0xF, 0xE2, .area9), // room 236, 4 cells, first at 12; Omega corridors (ROM tour)
    s(0xF, 0xFE, .queen), // room 237, 1 cells, first at 1; `ENTER_QUEEN`'s cell
    s(0xF, 0xFF, .queen), // room 238, 1 cells; unvisited: the Queen's room after the fight
    // Below the gates inside a room.
    s(0xA, 0x2A, .area2), // 34 remaining
    s(0xA, 0x50, .area5), // 15 remaining
    s(0xA, 0x65, .area3), // 26 remaining
    s(0xA, 0x86, .area7), // 6 remaining
    s(0xA, 0xB0, .area6), // 13 remaining
};

/// The gates that fall inside one of bank A's acid caves: the row where the
/// recording's first visits change area.
pub const cuts = [_]Cut{
    // Area 1's floor into area 2's shaft.
    edge(0xA, 0x08, .down), edge(0xA, 0x09, .down), edge(0xA, 0x0A, .down), edge(0xA, 0x0B, .down),
    // Area 3 into area 5.
    edge(0xA, 0x40, .down), edge(0xA, 0x41, .down),
    // Area 2 into area 3.
    edge(0xA, 0x54, .down), edge(0xA, 0x55, .down),
    // Area 6 into area 7.
    edge(0xA, 0x76, .down), edge(0xA, 0x77, .down),
    // Area 4 into area 6.
    edge(0xA, 0xA0, .down), edge(0xA, 0xA1, .down),
};

// ---- The graph --------------------------------------------------------------

/// What `fill` reads: which cells are in use, and which pairs are linked.
/// Built from the ROM by `graphOf`, or by hand in the tests.
pub const Graph = struct {
    in_use: [map.bank_count][map.cells]bool,
    links: []const Cut,
};

fn slot(at: Place) ?usize {
    if (at.bank < map.first_bank or at.bank > map.last_bank) return null;
    return @as(usize, at.bank - map.first_bank) * map.cells + at.cell;
}

/// Scroll joins from the world's rooms: neighbours neither of whose scroll
/// flags blocks the shared edge, as `roster.world` joins them.
pub fn graphOf(allocator: std.mem.Allocator, w: roster.World) !Graph {
    var g: Graph = .{ .in_use = undefined, .links = &.{} };
    var links: std.ArrayList(Cut) = .empty;
    errdefer links.deinit(allocator);
    for (0..map.bank_count) |bi| {
        const bank: u8 = map.first_bank + @as(u8, @intCast(bi));
        const cells = &w.banks[bi].cells;
        for (cells, 0..) |c, ci| {
            g.in_use[bi][ci] = c.inUse();
            if (!c.inUse()) continue;
            // Right and down only, so each pair goes in once.
            for ([_]Dir{ .right, .down }) |d| {
                const n = d.step(@intCast(ci)).?;
                if (!cells[n].inUse()) continue;
                const back: Dir = if (d == .right) .left else .up;
                if (d.blocks(c.scroll) or back.blocks(cells[n].scroll)) continue;
                try links.append(allocator, edge(bank, @intCast(ci), d));
            }
        }
    }
    g.links = try links.toOwnedSlice(allocator);
    return g;
}

// ---- The fill ---------------------------------------------------------------

pub const none: u8 = 0xFF;

pub const Table = [map.bank_count][map.cells]u8;

/// A link between two areas that no cut names: the data is missing a cut, or
/// a seed is in the wrong place.
pub const Clash = struct { link: Cut, a: Area, b: Area };

pub const Filled = struct {
    table: Table,
    clashes: []Clash,
    /// In-use cells no seed reached.
    unassigned: []Place,
    /// Cuts that match no link: a typo in the data.
    unused_cuts: []Cut,
    /// Seeds that another seed's area reached first.
    overrun_seeds: []Seed,

    pub fn deinit(self: *Filled, allocator: std.mem.Allocator) void {
        allocator.free(self.clashes);
        allocator.free(self.unassigned);
        allocator.free(self.unused_cuts);
        allocator.free(self.overrun_seeds);
    }

    pub fn areaOf(self: Filled, at: Place) ?Area {
        const v = self.table[at.bank - map.first_bank][at.cell];
        return if (v == none) null else @enumFromInt(v);
    }

    pub fn ok(self: Filled) bool {
        return self.clashes.len == 0 and self.unassigned.len == 0 and self.unused_cuts.len == 0 and self.overrun_seeds.len == 0;
    }
};

fn eqPlace(a: Place, b: Place) bool {
    return a.bank == b.bank and a.cell == b.cell;
}

fn isCut(l: Cut, cs: []const Cut) ?usize {
    for (cs, 0..) |c, i| {
        if ((eqPlace(l.a, c.a) and eqPlace(l.b, c.b)) or (eqPlace(l.a, c.b) and eqPlace(l.b, c.a))) return i;
    }
    return null;
}

fn placeOf(i: usize) Place {
    return p(map.first_bank + @as(u8, @intCast(i / map.cells)), @intCast(i % map.cells));
}

/// Spread every seed at once, one link per round, over the links no cut
/// names. Where two areas meet across an uncut link, that link is a clash.
/// With the cuts right, the result does not depend on where in its area a
/// seed sits; with one missing, the clash says where.
pub fn fill(allocator: std.mem.Allocator, g: Graph, ss: []const Seed, cs: []const Cut) !Filled {
    var table: Table = @splat(@splat(none));

    const n_slots = map.bank_count * map.cells;
    var adj: [n_slots]std.ArrayList(u16) = @splat(.empty);
    defer for (&adj) |*a| a.deinit(allocator);
    const cut_used = try allocator.alloc(bool, cs.len);
    defer allocator.free(cut_used);
    @memset(cut_used, false);
    var kept: std.ArrayList(Cut) = .empty;
    defer kept.deinit(allocator);
    for (g.links) |l| {
        if (isCut(l, cs)) |i| {
            cut_used[i] = true;
            continue;
        }
        const a = slot(l.a) orelse continue;
        const b = slot(l.b) orelse continue;
        try adj[a].append(allocator, @intCast(b));
        try adj[b].append(allocator, @intCast(a));
        try kept.append(allocator, l);
    }

    var overrun: std.ArrayList(Seed) = .empty;
    errdefer overrun.deinit(allocator);
    var queue: std.ArrayList(u16) = .empty;
    defer queue.deinit(allocator);
    for (ss) |sd| {
        const at = slot(sd.at) orelse continue;
        const here = &table[at / map.cells][at % map.cells];
        if (here.* != none) {
            if (here.* != @intFromEnum(sd.area)) try overrun.append(allocator, sd);
            continue;
        }
        here.* = @intFromEnum(sd.area);
        try queue.append(allocator, @intCast(at));
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const at = queue.items[head];
        const v = table[at / map.cells][at % map.cells];
        for (adj[at].items) |n| {
            const there = &table[n / map.cells][n % map.cells];
            if (there.* == none) {
                there.* = v;
                try queue.append(allocator, n);
            }
        }
    }

    var clashes: std.ArrayList(Clash) = .empty;
    errdefer clashes.deinit(allocator);
    for (kept.items) |l| {
        const va = table[slot(l.a).? / map.cells][slot(l.a).? % map.cells];
        const vb = table[slot(l.b).? / map.cells][slot(l.b).? % map.cells];
        if (va == none or vb == none or va == vb) continue;
        var dup = false;
        for (clashes.items) |c| dup = dup or isCut(l, &.{c.link}) != null;
        if (dup) continue;
        try clashes.append(allocator, .{ .link = l, .a = @enumFromInt(va), .b = @enumFromInt(vb) });
    }

    var unassigned: std.ArrayList(Place) = .empty;
    errdefer unassigned.deinit(allocator);
    for (0..map.bank_count) |bi| for (0..map.cells) |ci| {
        if (g.in_use[bi][ci] and table[bi][ci] == none) try unassigned.append(allocator, placeOf(bi * map.cells + ci));
    };
    var unused: std.ArrayList(Cut) = .empty;
    errdefer unused.deinit(allocator);
    for (cs, cut_used) |c, u| if (!u) try unused.append(allocator, c);

    return .{
        .table = table,
        .clashes = try clashes.toOwnedSlice(allocator),
        .unassigned = try unassigned.toOwnedSlice(allocator),
        .unused_cuts = try unused.toOwnedSlice(allocator),
        .overrun_seeds = try overrun.toOwnedSlice(allocator),
    };
}

pub const Error = error{AreaMapIncomplete};

/// The committed seeds and cuts over this ROM's rooms: the table the cart
/// carries. Refuses an incomplete or contradictory map rather than ship a
/// cell with no area.
pub fn tableOf(allocator: std.mem.Allocator, rom: []const u8) !Table {
    var w = try roster.world(allocator, rom);
    defer w.deinit(allocator);
    const g = try graphOf(allocator, w);
    defer allocator.free(g.links);
    var f = try fill(allocator, g, &seeds, &cuts);
    defer f.deinit(allocator);
    if (!f.ok()) return Error.AreaMapIncomplete;
    const ms = try roster.metroids(allocator, rom);
    defer allocator.free(ms);
    markNests(&f.table, w.room, ms);
    return f.table;
}

// ---- Colour sets --------------------------------------------------------------

/// Bit 7 of a cell's byte in the cart's table: the cell's room has a Metroid
/// spawn record, so it draws in its area's `nest` variant (green-leaning).
/// The low bits stay the area.
pub const nest_bit: u8 = 0x80;

/// Set the nest bit on every cell of each Metroid's room. Never on the
/// Queen's room: she is no spawn record, and her room keeps her own set.
pub fn markNests(t: *Table, room: [map.bank_count][map.cells]u16, ms: []const roster.Record) void {
    for (ms) |m| {
        if (m.bank < map.first_bank or m.bank > map.last_bank) continue;
        const r = room[m.bank - map.first_bank][m.cell];
        if (r == roster.World.none) continue;
        for (0..map.bank_count) |bi| for (0..map.cells) |ci| {
            if (room[bi][ci] != r) continue;
            const v = &t[bi][ci];
            if (v.* != none and v.* & ~nest_bit != @intFromEnum(Area.queen)) v.* |= nest_bit;
        };
    }
}

/// The colour set a screen draws in.
pub const Look = union(enum) {
    area: Area,
    /// The area's green-leaning variant: a Metroid room.
    nest: Area,
    /// The one shared purple set: a cave whose acid level changes.
    acid,
    /// The bubble sheet's rooms, wherever they are (colorization Step 9,
    /// James): Super Metroid's Bubble Mountain.
    bubbles,
};

/// The metatile table the bubble sheet's rooms load (`screens.tiletable_order`).
pub const bubbles_table: u4 = 2;

/// Queen > bubbles > nest > acid > area. `byte` is the cell's entry in the
/// cart's table; `table` is the loaded metatile table, which says whether
/// the room draws the bubbles or a lava table (`warp.isLavaTable`). The
/// engine knows it exactly at run time and no static reading of the ROM does.
pub fn lookOf(byte: u8, table: u4) Look {
    const area: Area = @enumFromInt(byte & ~nest_bit);
    if (area == .queen) return .{ .area = .queen };
    if (table == bubbles_table) return .bubbles;
    if (byte & nest_bit != 0) return .{ .nest = area };
    if (table >= 6 and table <= 8) return .acid;
    return .{ .area = area };
}

/// How many colour sets `full` carries: one per area, a `nest` variant of
/// each but the Queen's, `acid` and `bubbles`.
pub const set_count: usize = Area.count + (Area.count - 1) + 2;

/// A look's colour set, the index into `colors.full`'s per-set tables and the
/// cart's: the areas in id order, then their `nest` variants, then `acid`
/// and `bubbles`.
pub fn setOf(look: Look) u8 {
    return switch (look) {
        .area => |a| @intFromEnum(a),
        .nest => |a| @as(u8, Area.count) + @intFromEnum(a),
        .acid => Area.count + Area.count - 1,
        .bubbles => Area.count + Area.count,
    };
}

// ---- Tests ------------------------------------------------------------------

const testing = std.testing;

fn emptyGraph() Graph {
    return .{ .in_use = @splat(@splat(false)), .links = &.{} };
}

test "fill spreads each seed to its side of a cut, and no further" {
    // A row of five cells in bank 9, linked left to right, cut in the middle.
    var g = emptyGraph();
    var links: [4]Cut = undefined;
    for (0..5) |i| g.in_use[0][i] = true;
    for (0..4) |i| links[i] = edge(9, @intCast(i), .right);
    g.links = &links;
    // A door from the last cell to bank A, cell $10.
    g.in_use[1][0x10] = true;
    const with_door = links ++ [_]Cut{.{ .a = p(9, 4), .b = p(0xA, 0x10) }};
    g.links = &with_door;

    var f = try fill(testing.allocator, g, &.{
        .{ .at = p(9, 0), .area = .surface },
        .{ .at = p(9, 4), .area = .area1 },
    }, &.{edge(9, 2, .right)});
    defer f.deinit(testing.allocator);
    try testing.expect(f.ok());
    for (0..3) |i| try testing.expectEqual(Area.surface, f.areaOf(p(9, @intCast(i))).?);
    try testing.expectEqual(Area.area1, f.areaOf(p(9, 3)).?);
    try testing.expectEqual(Area.area1, f.areaOf(p(0xA, 0x10)).?);
    try testing.expectEqual(@as(?Area, null), f.areaOf(p(9, 5)));
}

test "fill reports a missing cut, an unreached cell, an unused cut and an overrun seed" {
    var g = emptyGraph();
    for (0..4) |i| g.in_use[0][i] = true;
    g.in_use[0][0x20] = true; // linked to nothing
    const links = [_]Cut{ edge(9, 0, .right), edge(9, 1, .right), edge(9, 2, .right) };
    g.links = &links;
    // The cut is written in the other order, which still matches.
    const cut_rev: Cut = .{ .a = p(9, 3), .b = p(9, 2) };
    var f = try fill(testing.allocator, g, &.{
        .{ .at = p(9, 0), .area = .area2 },
        .{ .at = p(9, 2), .area = .area3 },
        .{ .at = p(9, 2), .area = .area4 },
    }, &.{ cut_rev, edge(9, 0x40, .down) });
    defer f.deinit(testing.allocator);
    try testing.expect(!f.ok());
    // Areas 2 and 3 meet across the uncut link between cells 1 and 2... or 0
    // and 1: either way, exactly one link between them is reported.
    try testing.expectEqual(@as(usize, 1), f.clashes.len);
    try testing.expectEqual(Area.area2, f.clashes[0].a);
    try testing.expectEqual(Area.area3, f.clashes[0].b);
    try testing.expectEqual(@as(usize, 2), f.unassigned.len); // cell 3 (cut off) and $20
    try testing.expectEqual(@as(usize, 1), f.unused_cuts.len);
    try testing.expectEqual(@as(usize, 1), f.overrun_seeds.len);
    try testing.expectEqual(Area.area4, f.overrun_seeds[0].area);
}

test "with the cuts right, where a seed sits does not matter" {
    var g = emptyGraph();
    for (0..6) |i| g.in_use[0][i] = true;
    var links: [5]Cut = undefined;
    for (0..5) |i| links[i] = edge(9, @intCast(i), .right);
    g.links = &links;
    const cs = [_]Cut{edge(9, 1, .right)};
    for (0..2) |sa| for (2..6) |sb| {
        var f = try fill(testing.allocator, g, &.{
            .{ .at = p(9, @intCast(sa)), .area = .surface },
            .{ .at = p(9, @intCast(sb)), .area = .area1 },
        }, &cs);
        defer f.deinit(testing.allocator);
        try testing.expect(f.ok());
        for (0..6) |i| try testing.expectEqual(if (i < 2) Area.surface else Area.area1, f.areaOf(p(9, @intCast(i))).?);
    };
}

test "the grid wraps, as the screen coordinates do" {
    const c = edge(9, 0x0F, .right);
    try testing.expectEqual(@as(u8, 0x00), c.b.cell);
    const d = edge(9, 0xF3, .down);
    try testing.expectEqual(@as(u8, 0x03), d.b.cell);
}

test "the colour set: queen over bubbles over nest over acid over area" {
    const q: u8 = @intFromEnum(Area.queen);
    const a3: u8 = @intFromEnum(Area.area3);
    const lava: u4 = 7;
    const plain: u4 = 4;
    try testing.expectEqual(Look{ .area = .queen }, lookOf(q, lava));
    try testing.expectEqual(Look{ .area = .queen }, lookOf(q | nest_bit, bubbles_table));
    try testing.expectEqual(Look.bubbles, lookOf(a3 | nest_bit, bubbles_table));
    try testing.expectEqual(Look.bubbles, lookOf(a3, bubbles_table));
    try testing.expectEqual(Look{ .nest = .area3 }, lookOf(a3 | nest_bit, lava));
    try testing.expectEqual(Look{ .nest = .area3 }, lookOf(a3 | nest_bit, plain));
    try testing.expectEqual(Look.acid, lookOf(a3, lava));
    try testing.expectEqual(Look{ .area = .area3 }, lookOf(a3, plain));
}

test "every look the cart can reach has its own colour set" {
    var seen = [_]bool{false} ** set_count;
    const tables = [_]u4{ 4, 7, bubbles_table };
    for (0..Area.count) |ai| for ([_]bool{ false, true }) |nest| for (tables) |lava| {
        const byte: u8 = @as(u8, @intCast(ai)) | (if (nest and ai != @intFromEnum(Area.queen)) nest_bit else 0);
        const look = lookOf(byte, lava);
        const set = setOf(look);
        try testing.expect(set < set_count);
        seen[set] = true;
        // Two looks never share a set.
        for (0..Area.count) |bi| for ([_]bool{ false, true }) |nb| for (tables) |lb| {
            const other = lookOf(@as(u8, @intCast(bi)) | (if (nb and bi != @intFromEnum(Area.queen)) nest_bit else 0), lb);
            if (setOf(other) == set) try testing.expectEqual(look, other);
        };
    };
    for (seen) |v| try testing.expect(v);
}

test "a Metroid marks its whole room as a nest, and never the Queen's" {
    var t: Table = @splat(@splat(none));
    var room: [map.bank_count][map.cells]u16 = @splat(@splat(roster.World.none));
    // Room 1: cells $00-$02 in area 6; room 2: cell $10, the Queen's; room 3:
    // cell $20, area 6 with no Metroid.
    for (0..3) |i| {
        room[0][i] = 1;
        t[0][i] = @intFromEnum(Area.area6);
    }
    room[0][0x10] = 2;
    t[0][0x10] = @intFromEnum(Area.queen);
    room[0][0x20] = 3;
    t[0][0x20] = @intFromEnum(Area.area6);
    const rec = struct {
        fn r(cell: u8) roster.Record {
            return .{ .bank = 9, .cell = cell, .number = 0, .sprite = 0, .x = 0, .y = 0, .ai = 0 };
        }
    }.r;
    markNests(&t, room, &.{ rec(0x01), rec(0x01), rec(0x10) });
    for (0..3) |i| try testing.expectEqual(@intFromEnum(Area.area6) | nest_bit, t[0][i]);
    try testing.expectEqual(@as(u8, @intFromEnum(Area.queen)), t[0][0x10]);
    try testing.expectEqual(@as(u8, @intFromEnum(Area.area6)), t[0][0x20]);
    try testing.expectEqual(none, t[0][0x30]);
}

test "area labels" {
    try testing.expectEqualStrings("surface", Area.surface.label());
    try testing.expectEqualStrings("area 10", Area.area10.label());
    try testing.expectEqualStrings("queen", Area.queen.label());
}

const testrom = @import("testrom");

test "every in-use screen of the ROM has one area, and the gates fall where the GIF puts them" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    var w = try roster.world(gpa, rom);
    defer w.deinit(gpa);
    const g = try graphOf(gpa, w);
    defer gpa.free(g.links);
    var f = try fill(gpa, g, &seeds, &cuts);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), f.clashes.len);
    try testing.expectEqual(@as(usize, 0), f.unassigned.len);
    try testing.expectEqual(@as(usize, 0), f.unused_cuts.len);
    try testing.expectEqual(@as(usize, 0), f.overrun_seeds.len);

    const Expect = struct { at: Place, area: Area };
    for ([_]Expect{
        .{ .at = p(0xF, 0x76), .area = .surface }, // the ship
        .{ .at = p(0xF, 0x04), .area = .surface }, // the save station above "38 remaining"
        .{ .at = p(0xB, 0x0D), .area = .area1 }, // ...and the room below it
        .{ .at = p(0xA, 0x0A), .area = .area1 }, // "34 remaining", inside one cave
        .{ .at = p(0xA, 0x2A), .area = .area2 },
        .{ .at = p(0xA, 0x54), .area = .area2 }, // "26 remaining"
        .{ .at = p(0xA, 0x64), .area = .area3 },
        .{ .at = p(0xA, 0x40), .area = .area3 }, // "15 remaining"
        .{ .at = p(0xA, 0x50), .area = .area5 },
        .{ .at = p(0xA, 0xA0), .area = .area4 }, // "13 remaining"
        .{ .at = p(0xA, 0xB0), .area = .area6 },
        .{ .at = p(0xA, 0x76), .area = .area6 }, // "6 remaining"
        .{ .at = p(0xA, 0x86), .area = .area7 },
        .{ .at = p(0xB, 0x8D), .area = .area8 }, // Omega, kill 35
        .{ .at = p(0xF, 0xE0), .area = .area9 }, // Omega, kill 36
        .{ .at = p(0xA, 0xC9), .area = .area10 }, // the pit-trap corridors
        .{ .at = p(0xD, 0x00), .area = .area10 }, // larval, kill 45
        .{ .at = p(0xF, 0xFE), .area = .queen },
    }) |e| {
        errdefer std.debug.print("${X}:{X:0>2}\n", .{ e.at.bank, e.at.cell });
        try testing.expectEqual(e.area, f.areaOf(e.at).?);
    }
}

test "every Metroid's room is a nest, and the Queen's room isn't" {
    const gpa = testing.allocator;
    const rom = try testrom.load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(rom);

    const t = try tableOf(gpa, rom);
    const ms = try roster.metroids(gpa, rom);
    defer gpa.free(ms);
    try testing.expect(ms.len > 0);
    for (ms) |m| {
        errdefer std.debug.print("${X}:{X:0>2}\n", .{ m.bank, m.cell });
        try testing.expect(t[m.bank - map.first_bank][m.cell] & nest_bit != 0);
    }
    try testing.expectEqual(@as(u8, @intFromEnum(Area.queen)), t[0xF - map.first_bank][0xFE]);
    // A room with no Metroid: the ship's.
    try testing.expectEqual(@as(u8, @intFromEnum(Area.surface)), t[0xF - map.first_bank][0x76]);
}
