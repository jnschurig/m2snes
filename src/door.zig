//! Door scripts (bank 5).
//!
//! A door script is a variable-length opcode stream. The opcode's high nibble
//! selects the operation; several operations carry their only operand in the
//! low nibble. `$FF` ends a script.
//!
//! 512 pointers at 5:$42E5 index the scripts; the script bodies run from
//! 5:$46E5 to 5:$55A3. Doors are what actually load a room: they copy graphics
//! into VRAM, select the tile/collision/solidity tables, set damage values,
//! pick the song, and branch on Metroid count. Getting this stream right is a
//! precondition for Step 12 rendering anything at all.
//!
//! The decoder has an encoder beside it, and the gate re-encodes every script
//! and compares bytes. That is what makes "we understand this format" a
//! checkable claim rather than an assertion: a misread operand length would
//! desynchronise the stream and the round-trip would not close.

const std = @import("std");
const offsets = @import("offsets.zig");

pub const pointers_addr: u16 = 0x42E5;
pub const data_addr: u16 = 0x46E5;
pub const data_end: u16 = 0x55A3;
pub const bank: u8 = 5;
pub const pointer_count: usize = (data_addr - pointers_addr) / 2; // 512
pub const terminator: u8 = 0xFF;

pub const Copy = enum { data, bg, spr };
pub const Load = enum { bg, spr };

pub const Op = union(enum) {
    /// Copy from a banked source into VRAM. `dest` is a GB address in VRAM.
    copy: struct { which: Copy, src_bank: u8, src_addr: u16, dest: u16, len: u16 },
    tiletable: u4,
    collision: u4,
    solidity: u4,
    warp: struct { bank: u4, pos: u8 },
    escape_queen,
    damage: struct { acid: u8, spike: u8 },
    exit_queen,
    enter_queen: struct { bank: u4, scroll_y: u16, scroll_x: u16, samus_y: u16, samus_x: u16 },
    if_met_less: struct { met_count: u8, transition: u16 },
    fadeout,
    load: struct { which: Load, src_bank: u8, src_addr: u16 },
    song: u4,
    item: u4,
    end,

    /// Total encoded size, opcode byte included.
    pub fn size(self: Op) usize {
        return switch (self) {
            .copy => 8,
            .warp => 2,
            .damage => 3,
            .enter_queen => 9,
            .if_met_less => 4,
            .load => 4,
            else => 1,
        };
    }
};

pub const Error = error{
    UnknownOpcode,
    TruncatedOperand,
    UnterminatedScript,
    BadCopyVariant,
    BadLoadVariant,
};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn u8_(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return Error.TruncatedOperand;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }
    fn u16_(self: *Reader) !u16 {
        const lo = try self.u8_();
        const hi = try self.u8_();
        return @as(u16, lo) | (@as(u16, hi) << 8);
    }
};

/// Decode one operation. Advances `pos` past it.
pub fn decodeOne(r: *Reader) Error!Op {
    const opcode = try r.u8_();
    if (opcode == terminator) return .end;
    const low: u4 = @truncate(opcode);
    return switch (opcode >> 4) {
        0x0 => .{ .copy = .{
            .which = switch (low) {
                0 => .data,
                1 => .bg,
                2 => .spr,
                else => return Error.BadCopyVariant,
            },
            .src_bank = try r.u8_(),
            .src_addr = try r.u16_(),
            .dest = try r.u16_(),
            .len = try r.u16_(),
        } },
        0x1 => .{ .tiletable = low },
        0x2 => .{ .collision = low },
        0x3 => .{ .solidity = low },
        0x4 => .{ .warp = .{ .bank = low, .pos = try r.u8_() } },
        0x5 => .escape_queen,
        0x6 => .{ .damage = .{ .acid = try r.u8_(), .spike = try r.u8_() } },
        0x7 => .exit_queen,
        0x8 => .{ .enter_queen = .{
            .bank = low,
            .scroll_y = try r.u16_(),
            .scroll_x = try r.u16_(),
            .samus_y = try r.u16_(),
            .samus_x = try r.u16_(),
        } },
        0x9 => .{ .if_met_less = .{ .met_count = try r.u8_(), .transition = try r.u16_() } },
        0xA => .fadeout,
        0xB => .{ .load = .{
            .which = switch (low) {
                1 => .bg,
                2 => .spr,
                else => return Error.BadLoadVariant,
            },
            .src_bank = try r.u8_(),
            .src_addr = try r.u16_(),
        } },
        0xC => .{ .song = low },
        0xD => .{ .item = low },
        // $E and $F (other than the $FF terminator) are not operations. The
        // reference extractor silently ignores them, which would desynchronise
        // the stream; refusing is the only safe reading.
        else => Error.UnknownOpcode,
    };
}

pub fn encodeOne(op: Op, out: []u8) usize {
    var n: usize = 0;
    const put8 = struct {
        fn f(buf: []u8, i: *usize, v: u8) void {
            buf[i.*] = v;
            i.* += 1;
        }
    }.f;
    const put16 = struct {
        fn f(buf: []u8, i: *usize, v: u16) void {
            buf[i.*] = @truncate(v);
            buf[i.* + 1] = @truncate(v >> 8);
            i.* += 2;
        }
    }.f;

    switch (op) {
        .copy => |c| {
            put8(out, &n, @as(u8, switch (c.which) {
                .data => 0x00,
                .bg => 0x01,
                .spr => 0x02,
            }));
            put8(out, &n, c.src_bank);
            put16(out, &n, c.src_addr);
            put16(out, &n, c.dest);
            put16(out, &n, c.len);
        },
        .tiletable => |v| put8(out, &n, 0x10 | @as(u8, v)),
        .collision => |v| put8(out, &n, 0x20 | @as(u8, v)),
        .solidity => |v| put8(out, &n, 0x30 | @as(u8, v)),
        .warp => |v| {
            put8(out, &n, 0x40 | @as(u8, v.bank));
            put8(out, &n, v.pos);
        },
        .escape_queen => put8(out, &n, 0x50),
        .damage => |v| {
            put8(out, &n, 0x60);
            put8(out, &n, v.acid);
            put8(out, &n, v.spike);
        },
        .exit_queen => put8(out, &n, 0x70),
        .enter_queen => |v| {
            put8(out, &n, 0x80 | @as(u8, v.bank));
            put16(out, &n, v.scroll_y);
            put16(out, &n, v.scroll_x);
            put16(out, &n, v.samus_y);
            put16(out, &n, v.samus_x);
        },
        .if_met_less => |v| {
            put8(out, &n, 0x90);
            put8(out, &n, v.met_count);
            put16(out, &n, v.transition);
        },
        .fadeout => put8(out, &n, 0xA0),
        .load => |v| {
            put8(out, &n, 0xB0 | @as(u8, switch (v.which) {
                .bg => 1,
                .spr => 2,
            }));
            put8(out, &n, v.src_bank);
            put16(out, &n, v.src_addr);
        },
        .song => |v| put8(out, &n, 0xC0 | @as(u8, v)),
        .item => |v| put8(out, &n, 0xD0 | @as(u8, v)),
        .end => put8(out, &n, terminator),
    }
    return n;
}

/// Decode the whole contiguous script region as one operation stream.
///
/// The region is decoded as a stream rather than script by script: scripts are
/// not independently framed, and several pointers land in the middle of what a
/// linear read sees as one run. Decoding once and indexing the pointers into
/// the result is the only reading that cannot double-count.
pub const Decoded = struct {
    ops: std.ArrayList(Op),
    /// Byte offset within the region where each op starts, parallel to `ops`.
    starts: std.ArrayList(u16),

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        self.ops.deinit(allocator);
        self.starts.deinit(allocator);
    }

    /// Index into `ops` of the op starting at `gb_addr`, or null when the
    /// address is not on an operation boundary.
    pub fn indexOfAddr(self: Decoded, gb_addr: u16) ?usize {
        if (gb_addr < data_addr) return null;
        const rel: u16 = gb_addr - data_addr;
        return std.sort.binarySearch(u16, self.starts.items, rel, struct {
            fn cmp(key: u16, mid: u16) std.math.Order {
                return std.math.order(key, mid);
            }
        }.cmp);
    }
};

pub fn decodeRegion(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    var d: Decoded = .{ .ops = .empty, .starts = .empty };
    errdefer d.deinit(allocator);
    var r: Reader = .{ .bytes = bytes };
    while (r.pos < bytes.len) {
        const start = r.pos;
        const op = try decodeOne(&r);
        try d.starts.append(allocator, @intCast(start));
        try d.ops.append(allocator, op);
    }
    return d;
}

/// The 512 script pointers, as GB addresses.
pub fn pointers(rom: []const u8) ?[]const u8 {
    const e = offsets.find("door_pointers") orelse return null;
    if (e.romEnd() > rom.len) return null;
    return rom[e.romOffset()..e.romEnd()];
}

pub fn region(rom: []const u8) ?[]const u8 {
    const e = offsets.find("door_data") orelse return null;
    if (e.romEnd() > rom.len) return null;
    return rom[e.romOffset()..e.romEnd()];
}

/// Human-readable rendering, one operation per line. Source addresses are
/// resolved to offsets-table names where one exists, which cross-checks the
/// two: a door script that copies from an address we have no name for is
/// either a gap in the table or a misparse.
pub fn write(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), op: Op) !void {
    switch (op) {
        .copy => |c| {
            try buf.print(allocator, "    COPY_{s} ", .{@tagName(c.which)});
            try writeSource(allocator, buf, c.src_bank, c.src_addr);
            try buf.print(allocator, ", ${X:0>4}, ${X:0>4}\n", .{ c.dest, c.len });
        },
        .tiletable => |v| try buf.print(allocator, "    TILETABLE ${X}\n", .{v}),
        .collision => |v| try buf.print(allocator, "    COLLISION ${X}\n", .{v}),
        .solidity => |v| try buf.print(allocator, "    SOLIDITY ${X}\n", .{v}),
        .warp => |v| try buf.print(allocator, "    WARP ${X}, ${X:0>2}\n", .{ v.bank, v.pos }),
        .escape_queen => try buf.appendSlice(allocator, "    ESCAPE_QUEEN\n"),
        .damage => |v| try buf.print(allocator, "    DAMAGE ${X:0>2}, ${X:0>2}\n", .{ v.acid, v.spike }),
        .exit_queen => try buf.appendSlice(allocator, "    EXIT_QUEEN\n"),
        .enter_queen => |v| try buf.print(allocator, "    ENTER_QUEEN ${X}, ${X:0>4}, ${X:0>4}, ${X:0>4}, ${X:0>4}\n", .{
            v.bank, v.scroll_y, v.scroll_x, v.samus_y, v.samus_x,
        }),
        .if_met_less => |v| try buf.print(allocator, "    IF_MET_LESS ${X:0>2}, ${X:0>4}\n", .{ v.met_count, v.transition }),
        .fadeout => try buf.appendSlice(allocator, "    FADEOUT\n"),
        .load => |v| {
            try buf.print(allocator, "    LOAD_{s} ", .{@tagName(v.which)});
            try writeSource(allocator, buf, v.src_bank, v.src_addr);
            try buf.append(allocator, '\n');
        },
        .song => |v| try buf.print(allocator, "    SONG ${X}\n", .{v}),
        .item => |v| try buf.print(allocator, "    ITEM ${X}\n", .{v}),
        .end => try buf.appendSlice(allocator, "    END_DOOR\n"),
    }
}

/// A door source address resolved against the offsets table.
///
/// Doors address sub-ranges of entries, not only their starts: the four rows
/// of `bg_queenHead` are copied individually out of one `$80`-byte entry. So
/// resolution is containment, not equality, and carries the offset within.
pub const Source = struct { name: []const u8, delta: usize };

pub fn resolveSource(src_bank: u8, src_addr: u16) ?Source {
    const target = @as(usize, src_bank) * offsets.bank_size + (src_addr & 0x3FFF);
    for (offsets.entries) |e| {
        if (target >= e.romOffset() and target < e.romEnd()) {
            return .{ .name = e.name, .delta = target - e.romOffset() };
        }
    }
    return null;
}

fn writeSource(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), src_bank: u8, src_addr: u16) !void {
    if (resolveSource(src_bank, src_addr)) |src| {
        if (src.delta == 0) {
            try buf.appendSlice(allocator, src.name);
        } else {
            try buf.print(allocator, "{s}+${X:0>2}", .{ src.name, src.delta });
        }
    } else {
        try buf.print(allocator, "${X:0>2}:{X:0>4}", .{ src_bank, src_addr });
    }
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

test "every operation round-trips through decode and encode" {
    const ops = [_]Op{
        .{ .copy = .{ .which = .data, .src_bank = 7, .src_addr = 0x4000, .dest = 0x8B00, .len = 0x0800 } },
        .{ .copy = .{ .which = .bg, .src_bank = 8, .src_addr = 0x69BC, .dest = 0x9C00, .len = 0x0020 } },
        .{ .copy = .{ .which = .spr, .src_bank = 6, .src_addr = 0x5920, .dest = 0x8B00, .len = 0x0400 } },
        .{ .tiletable = 0xA }, .{ .collision = 3 },        .{ .solidity = 7 },
        .{ .warp = .{ .bank = 9, .pos = 0x34 } },          .escape_queen,
        .{ .damage = .{ .acid = 0x10, .spike = 0x08 } },   .exit_queen,
        .{ .enter_queen = .{ .bank = 0xF, .scroll_y = 0x0123, .scroll_x = 0x4567, .samus_y = 0x89AB, .samus_x = 0xCDEF } },
        .{ .if_met_less = .{ .met_count = 0x46, .transition = 0x1234 } },
        .fadeout,
        .{ .load = .{ .which = .bg, .src_bank = 7, .src_addr = 0x5000 } },
        .{ .load = .{ .which = .spr, .src_bank = 8, .src_addr = 0x79BC } },
        .{ .song = 0xE }, .{ .item = 5 }, .end,
    };
    for (ops) |op| {
        var buf: [16]u8 = undefined;
        const n = encodeOne(op, &buf);
        try testing.expectEqual(op.size(), n);
        var r: Reader = .{ .bytes = buf[0..n] };
        const back = try decodeOne(&r);
        try testing.expectEqual(n, r.pos);
        try testing.expectEqualDeep(op, back);
    }
}

test "unknown opcodes are refused rather than skipped" {
    // $E0 is not an operation, and $F0 is not the $FF terminator.
    for ([_]u8{ 0xE0, 0xE7, 0xF0, 0xFE }) |bad| {
        var r: Reader = .{ .bytes = &[_]u8{bad} };
        try testing.expectError(Error.UnknownOpcode, decodeOne(&r));
    }
    // Variants outside the defined set are refused too.
    var r3: Reader = .{ .bytes = &[_]u8{ 0x03, 0, 0, 0, 0, 0, 0, 0 } };
    try testing.expectError(Error.BadCopyVariant, decodeOne(&r3));
    var r4: Reader = .{ .bytes = &[_]u8{ 0xB0, 0, 0, 0 } };
    try testing.expectError(Error.BadLoadVariant, decodeOne(&r4));
}

test "a truncated operand fails instead of reading past the end" {
    var r: Reader = .{ .bytes = &[_]u8{ 0x00, 0x07, 0x00 } }; // COPY_DATA, 2 of 7 operand bytes
    try testing.expectError(Error.TruncatedOperand, decodeOne(&r));
}

test "source resolution is containment, not equality" {
    // bg_queenHead is one $80-byte entry; doors copy its four $20-byte rows
    // individually, so an exact-match lookup would fail on three of the four.
    const head = resolveSource(8, 0x4000) orelse return error.Unresolved;
    try testing.expectEqualStrings("bg_queenHead", head.name);
    try testing.expectEqual(@as(usize, 0), head.delta);
    const row3 = resolveSource(8, 0x4040) orelse return error.Unresolved;
    try testing.expectEqualStrings("bg_queenHead", row3.name);
    try testing.expectEqual(@as(usize, 0x40), row3.delta);
    // An address in a bank with no entry covering it stays unresolved.
    try testing.expectEqual(@as(?Source, null), resolveSource(0, 0x4000));
}

test "the door region constants agree with offsets.zig" {
    const p = offsets.find("door_pointers") orelse return error.Missing;
    const d = offsets.find("door_data") orelse return error.Missing;
    try testing.expectEqual(pointers_addr, p.gb_addr);
    try testing.expectEqual(data_addr, d.gb_addr);
    try testing.expectEqual(@as(usize, data_end - data_addr), d.size);
    try testing.expectEqual(pointer_count * 2, p.size);
    try testing.expectEqual(bank, p.bank);
    try testing.expectEqual(bank, d.bank);
    try testing.expectEqual(p.romEnd(), d.romOffset()); // gapless
}

test "gb/probe.zig's copy of this region agrees with it" {
    // `gb/probe.zig` watches reads of the door script region, and deliberately
    // does not import this file: `gb/` is the emulator, and it should not need
    // to know Metroid II's data layout to be built or tested. The four
    // constants it duplicates are checked from this side, where both are in
    // reach, so the duplication cannot drift unnoticed.
    const probe = @import("gb/probe.zig");
    try testing.expectEqual(@as(usize, bank), probe.door_bank);
    try testing.expectEqual(data_addr, probe.door_data_start);
    try testing.expectEqual(data_end, probe.door_data_end);
    try testing.expectEqual(pointers_addr, probe.door_pointers_start);
}
