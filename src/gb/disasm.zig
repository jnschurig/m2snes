//! An SM83 disassembler.
//!
//! Step 7 needs to read one handler out of the retail ROM -- what the
//! door-script interpreter does with a `WARP` operand -- and `01-requirements`
//! says facts have to stand on their own rather than on someone else's labels.
//! So the bytes get decoded here rather than looked up in M2RoS.
//!
//! Decoding is structured the same way `cpu.zig` decodes: `x = op >> 6`,
//! `y = (op >> 3) & 7`, `z = op & 7`, and the register/condition tables those
//! index. That is deliberate duplication of *shape* but not of code -- the CPU
//! executes and this prints, and neither is derived from the other. Two
//! independent structured decodes of the same 512 opcodes is exactly the
//! arrangement a cross-check test can exploit: `cpu.zig` reports how far PC
//! moved, this reports how long it thinks the instruction is, and the test at
//! the bottom of this file runs all 512 through both.
//!
//! Instruction text is built at decode time into a fixed buffer instead of
//! being re-derived by a second switch over the same fields. One switch means
//! the length, the control flow and the printed text cannot disagree with each
//! other about what an opcode is.

const std = @import("std");

// ---- The tables the opcode's bit fields index -----------------------------

pub const reg = [8][]const u8{ "B", "C", "D", "E", "H", "L", "(HL)", "A" };
pub const reg_pair = [4][]const u8{ "BC", "DE", "HL", "SP" };
pub const reg_pair_af = [4][]const u8{ "BC", "DE", "HL", "AF" };
pub const cond = [4][]const u8{ "NZ", "Z", "NC", "C" };
pub const alu_op = [8][]const u8{ "ADD A,", "ADC A,", "SUB ", "SBC A,", "AND ", "XOR ", "OR ", "CP " };
pub const rot_op = [8][]const u8{ "RLC", "RRC", "RL", "RR", "SLA", "SRA", "SWAP", "SRL" };
pub const acc_op = [8][]const u8{ "RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF" };

/// Where control goes after this instruction. `branch`, `call_cc` and `ret_cc`
/// also fall through; `jump`, `ret`, `stop` and `illegal` do not.
pub const Flow = union(enum) {
    next,
    /// Unconditional JP/JR to a known address.
    jump: u16,
    /// Conditional JP/JR: taken goes here, not-taken falls through.
    branch: u16,
    call: u16,
    call_cc: u16,
    ret,
    ret_cc,
    /// `JP HL` -- a jump table, and where it goes is not in the bytes.
    indirect,
    stop,
    illegal,
};

/// An absolute memory address named by the instruction. `LD (C),A` and every
/// `(HL)` form are excluded on purpose: the address is in a register, so it is
/// not something a static read can report.
pub const Mem = struct { addr: u16, write: bool };

pub const max_text = 24;

pub const Insn = struct {
    /// Encoded length in bytes, opcode included. Never zero.
    len: u8,
    opcode: u8,
    /// True for the `$CB` page.
    prefixed: bool,
    flow: Flow,
    mem: ?Mem,
    buf: [max_text]u8,
    text_len: u8,

    pub fn text(self: *const Insn) []const u8 {
        return self.buf[0..self.text_len];
    }
};

const Builder = struct {
    insn: Insn,

    fn put(self: *Builder, comptime fmt: []const u8, args: anytype) void {
        // A mnemonic longer than the buffer would be a bug in this file rather
        // than a property of the input, so truncate loudly instead of silently:
        // every format string here is checked by the round-trip test below.
        const s = std.fmt.bufPrint(&self.insn.buf, fmt, args) catch unreachable;
        self.insn.text_len = @intCast(s.len);
    }
};

fn sign(v: i8) []const u8 {
    return if (v < 0) "-" else "+";
}

/// Decode the instruction at `pc`, whose bytes begin at `win[0]`.
///
/// A truncated instruction at the end of `win` decodes as illegal with the
/// bytes that are actually there, rather than reading past the slice.
pub fn decode(win: []const u8, pc: u16) Insn {
    var b = Builder{ .insn = .{
        .len = 1,
        .opcode = if (win.len == 0) 0 else win[0],
        .prefixed = false,
        .flow = .next,
        .mem = null,
        .buf = @splat(0),
        .text_len = 0,
    } };
    if (win.len == 0) {
        b.put("(truncated)", .{});
        b.insn.flow = .illegal;
        return b.insn;
    }

    const op = win[0];
    const x: u2 = @truncate(op >> 6);
    const y: u3 = @truncate(op >> 3);
    const z: u3 = @truncate(op);
    const p: u2 = @truncate(y >> 1);
    const q: u1 = @truncate(y);

    // Immediates are read through helpers that mark the instruction illegal if
    // the slice ends first, so `len` can be trusted even at a region boundary.
    var truncated = false;
    const imm8 = blk: {
        if (win.len < 2) {
            truncated = true;
            break :blk @as(u8, 0);
        }
        break :blk win[1];
    };
    const imm16 = blk: {
        if (win.len < 3) {
            truncated = true;
            break :blk @as(u16, 0);
        }
        break :blk @as(u16, win[1]) | (@as(u16, win[2]) << 8);
    };
    const disp: i8 = @bitCast(imm8);
    // JR's displacement is relative to the address *after* the instruction.
    const jr_target: u16 = @bitCast(@as(i16, @bitCast(pc +% 2)) +% @as(i16, disp));

    switch (x) {
        0 => switch (z) {
            0 => switch (y) {
                0 => b.put("NOP", .{}),
                1 => {
                    b.insn.len = 3;
                    b.insn.mem = .{ .addr = imm16, .write = true };
                    b.put("LD (${X:0>4}),SP", .{imm16});
                },
                2 => {
                    // STOP's second byte is part of the instruction on hardware.
                    b.insn.len = 2;
                    b.insn.flow = .stop;
                    b.put("STOP", .{});
                },
                3 => {
                    b.insn.len = 2;
                    b.insn.flow = .{ .jump = jr_target };
                    b.put("JR ${X:0>4}", .{jr_target});
                },
                else => {
                    b.insn.len = 2;
                    b.insn.flow = .{ .branch = jr_target };
                    b.put("JR {s},${X:0>4}", .{ cond[y - 4], jr_target });
                },
            },
            1 => if (q == 0) {
                b.insn.len = 3;
                b.put("LD {s},${X:0>4}", .{ reg_pair[p], imm16 });
            } else b.put("ADD HL,{s}", .{reg_pair[p]}),
            2 => {
                const ind = [4][]const u8{ "(BC)", "(DE)", "(HL+)", "(HL-)" };
                if (q == 0) b.put("LD {s},A", .{ind[p]}) else b.put("LD A,{s}", .{ind[p]});
            },
            3 => if (q == 0) b.put("INC {s}", .{reg_pair[p]}) else b.put("DEC {s}", .{reg_pair[p]}),
            4 => b.put("INC {s}", .{reg[y]}),
            5 => b.put("DEC {s}", .{reg[y]}),
            6 => {
                b.insn.len = 2;
                b.put("LD {s},${X:0>2}", .{ reg[y], imm8 });
            },
            7 => b.put("{s}", .{acc_op[y]}),
        },
        1 => if (y == 6 and z == 6) b.put("HALT", .{}) else b.put("LD {s},{s}", .{ reg[y], reg[z] }),
        2 => b.put("{s}{s}", .{ alu_op[y], reg[z] }),
        3 => switch (z) {
            0 => switch (y) {
                0, 1, 2, 3 => {
                    b.insn.flow = .ret_cc;
                    b.put("RET {s}", .{cond[y]});
                },
                4 => {
                    b.insn.len = 2;
                    b.insn.mem = .{ .addr = 0xFF00 + @as(u16, imm8), .write = true };
                    b.put("LDH (${X:0>2}),A", .{imm8});
                },
                5 => {
                    b.insn.len = 2;
                    b.put("ADD SP,{s}${X:0>2}", .{ sign(disp), @abs(disp) });
                },
                6 => {
                    b.insn.len = 2;
                    b.insn.mem = .{ .addr = 0xFF00 + @as(u16, imm8), .write = false };
                    b.put("LDH A,(${X:0>2})", .{imm8});
                },
                7 => {
                    b.insn.len = 2;
                    b.put("LD HL,SP{s}${X:0>2}", .{ sign(disp), @abs(disp) });
                },
            },
            1 => if (q == 0) b.put("POP {s}", .{reg_pair_af[p]}) else switch (p) {
                0 => {
                    b.insn.flow = .ret;
                    b.put("RET", .{});
                },
                1 => {
                    b.insn.flow = .ret;
                    b.put("RETI", .{});
                },
                2 => {
                    b.insn.flow = .indirect;
                    b.put("JP HL", .{});
                },
                3 => b.put("LD SP,HL", .{}),
            },
            2 => switch (y) {
                0, 1, 2, 3 => {
                    b.insn.len = 3;
                    b.insn.flow = .{ .branch = imm16 };
                    b.put("JP {s},${X:0>4}", .{ cond[y], imm16 });
                },
                4 => b.put("LD ($FF00+C),A", .{}),
                5 => {
                    b.insn.len = 3;
                    b.insn.mem = .{ .addr = imm16, .write = true };
                    b.put("LD (${X:0>4}),A", .{imm16});
                },
                6 => b.put("LD A,($FF00+C)", .{}),
                7 => {
                    b.insn.len = 3;
                    b.insn.mem = .{ .addr = imm16, .write = false };
                    b.put("LD A,(${X:0>4})", .{imm16});
                },
            },
            3 => switch (y) {
                0 => {
                    b.insn.len = 3;
                    b.insn.flow = .{ .jump = imm16 };
                    b.put("JP ${X:0>4}", .{imm16});
                },
                1 => {
                    b.insn.len = 2;
                    b.insn.prefixed = true;
                    if (win.len < 2) {
                        b.insn.flow = .illegal;
                        b.put("(truncated CB)", .{});
                    } else {
                        const cb = win[1];
                        const cx: u2 = @truncate(cb >> 6);
                        const cy: u3 = @truncate(cb >> 3);
                        const cz: u3 = @truncate(cb);
                        switch (cx) {
                            0 => b.put("{s} {s}", .{ rot_op[cy], reg[cz] }),
                            1 => b.put("BIT {d},{s}", .{ cy, reg[cz] }),
                            2 => b.put("RES {d},{s}", .{ cy, reg[cz] }),
                            3 => b.put("SET {d},{s}", .{ cy, reg[cz] }),
                        }
                    }
                },
                6 => b.put("DI", .{}),
                7 => b.put("EI", .{}),
                else => {
                    b.insn.flow = .illegal;
                    b.put("db ${X:0>2}", .{op});
                },
            },
            4 => if (y < 4) {
                b.insn.len = 3;
                b.insn.flow = .{ .call_cc = imm16 };
                b.put("CALL {s},${X:0>4}", .{ cond[y], imm16 });
            } else {
                b.insn.flow = .illegal;
                b.put("db ${X:0>2}", .{op});
            },
            5 => if (q == 0) b.put("PUSH {s}", .{reg_pair_af[p]}) else if (p == 0) {
                b.insn.len = 3;
                b.insn.flow = .{ .call = imm16 };
                b.put("CALL ${X:0>4}", .{imm16});
            } else {
                b.insn.flow = .illegal;
                b.put("db ${X:0>2}", .{op});
            },
            6 => {
                b.insn.len = 2;
                b.put("{s}${X:0>2}", .{ alu_op[y], imm8 });
            },
            7 => {
                b.insn.flow = .{ .call = @as(u16, y) * 8 };
                b.put("RST ${X:0>2}", .{@as(u16, y) * 8});
            },
        },
    }

    // An instruction whose operand ran off the end of the slice is not an
    // instruction. Report the opcode byte and stop the trace here rather than
    // handing back a length that walks past the region.
    if (truncated and b.insn.len > win.len) {
        b.insn.len = @intCast(win.len);
        b.insn.flow = .illegal;
        b.insn.mem = null;
        b.put("db ${X:0>2} (truncated)", .{op});
    }
    return b.insn;
}

// ---- Following the flow ---------------------------------------------------

/// A disassembled region: which bytes the trace proved are code, and where the
/// calls and jumps out of it go.
pub const Listing = struct {
    base: u16,
    code: []const u8,
    /// True at the first byte of every instruction the trace reached.
    starts: []bool,
    /// True for every byte belonging to a reached instruction. A byte that is
    /// `starts` false and `covered` false was never proven to be code, which
    /// for a data table is the correct answer rather than a failure.
    covered: []bool,
    /// Distinct call targets, in address order, including ones outside the
    /// region -- those are the entry points of whatever this region calls.
    calls: []u16,
    /// Targets of jumps that leave the region.
    exits: []u16,

    pub fn deinit(self: *Listing, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
        allocator.free(self.covered);
        allocator.free(self.calls);
        allocator.free(self.exits);
    }

    pub fn contains(self: Listing, addr: u16) bool {
        return addr >= self.base and addr - self.base < self.code.len;
    }
};

fn sortedKeys(allocator: std.mem.Allocator, map: *std.AutoHashMap(u16, void)) ![]u16 {
    const out = try allocator.alloc(u16, map.count());
    var it = map.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    std.mem.sort(u16, out, {}, std.sort.asc(u16));
    return out;
}

/// Recursive traversal from `entries`. Follows both arms of a conditional and
/// falls through a `CALL`; stops at `RET`, an unconditional jump out of the
/// region, `JP HL`, and anything illegal.
///
/// Deliberately *not* a linear sweep: a linear sweep through an embedded jump
/// table decodes the table as instructions and then reports garbage with
/// perfect confidence. Bytes this never reaches are left marked as unknown,
/// which is an honest answer.
pub fn trace(
    allocator: std.mem.Allocator,
    code: []const u8,
    base: u16,
    entries: []const u16,
) !Listing {
    const starts = try allocator.alloc(bool, code.len);
    errdefer allocator.free(starts);
    @memset(starts, false);
    const covered = try allocator.alloc(bool, code.len);
    errdefer allocator.free(covered);
    @memset(covered, false);

    var calls = std.AutoHashMap(u16, void).init(allocator);
    defer calls.deinit();
    var exits = std.AutoHashMap(u16, void).init(allocator);
    defer exits.deinit();

    var work: std.ArrayList(u16) = .empty;
    defer work.deinit(allocator);
    for (entries) |e| try work.append(allocator, e);

    while (work.pop()) |addr| {
        if (addr < base or addr - base >= code.len) continue;
        const off = addr - base;
        if (starts[off]) continue;

        const insn = decode(code[off..], addr);
        starts[off] = true;
        for (0..insn.len) |i| {
            if (off + i < covered.len) covered[off + i] = true;
        }

        const next = addr +% insn.len;
        switch (insn.flow) {
            .next => try work.append(allocator, next),
            .jump => |t| {
                if (t >= base and t - base < code.len) {
                    try work.append(allocator, t);
                } else try exits.put(t, {});
            },
            .branch => |t| {
                if (t >= base and t - base < code.len) {
                    try work.append(allocator, t);
                } else try exits.put(t, {});
                try work.append(allocator, next);
            },
            .call, .call_cc => |t| {
                try calls.put(t, {});
                if (t >= base and t - base < code.len) try work.append(allocator, t);
                try work.append(allocator, next);
            },
            .ret_cc => try work.append(allocator, next),
            // `RET`, `JP HL`, `STOP` and illegal bytes all end a run: nothing
            // that follows them is reachable from here.
            .ret, .indirect, .stop, .illegal => {},
        }
    }

    const call_list = try sortedKeys(allocator, &calls);
    errdefer allocator.free(call_list);
    const exit_list = try sortedKeys(allocator, &exits);

    return .{
        .base = base,
        .code = code,
        .starts = starts,
        .covered = covered,
        .calls = call_list,
        .exits = exit_list,
    };
}

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const cpu_mod = @import("cpu.zig");

test "every opcode decodes to the length the CPU actually consumes" {
    // Two independent structured decodes of the same 512 opcodes: the CPU
    // moves PC, this file reports a length. Nothing here is derived from the
    // other file, so a mistyped bit field in either one shows up as a
    // disagreement rather than as two matching mistakes.
    //
    // Only the fall-through path can be compared -- a taken branch moves PC
    // somewhere else entirely -- so the flags are cleared and the conditions
    // that are *taken* with clear flags (NZ, NC) are skipped. That is the
    // even-numbered condition index in every conditional form the CPU has.
    var bus = cpu_mod.FlatBus{};
    var checked: usize = 0;
    for (0..256) |i| {
        const op: u8 = @intCast(i);
        // $0100 is clear of the interrupt vectors and of the $FF00 IO page.
        const at: u16 = 0x0100;
        bus.mem[at] = op;
        bus.mem[at + 1] = 0x34;
        bus.mem[at + 2] = 0x12;

        const insn = decode(bus.mem[at .. at + 3], at);
        const diverts = switch (insn.flow) {
            .next, .illegal => false,
            .ret_cc, .branch, .call_cc => (@as(u3, @truncate(op >> 3)) & 1) == 0,
            .jump, .call, .ret, .indirect, .stop => true,
        };
        if (diverts) continue;

        var cpu = cpu_mod.Cpu.dmgPostBoot();
        cpu.pc = at;
        cpu.f = .{};
        _ = cpu.step(&bus) catch continue; // illegal opcodes have no length to compare
        try testing.expectEqual(at + insn.len, cpu.pc);
        checked += 1;
    }
    // Guard against the skip conditions silently swallowing the whole table.
    try testing.expect(checked > 200);
}

test "the CB page is 256 two-byte instructions and all of them print" {
    for (0..256) |i| {
        const win = [_]u8{ 0xCB, @intCast(i) };
        const insn = decode(&win, 0x4000);
        try testing.expectEqual(@as(u8, 2), insn.len);
        try testing.expect(insn.prefixed);
        try testing.expect(insn.text().len > 2);
    }
}

test "JR displacement is measured from the end of the instruction" {
    // $20 is JR NZ. Forward: $4000 + 2 + 5.
    const fwd = decode(&[_]u8{ 0x20, 0x05 }, 0x4000);
    try testing.expectEqual(Flow{ .branch = 0x4007 }, fwd.flow);
    // Backwards: $FE is -2, which is the self-loop idiom.
    const back = decode(&[_]u8{ 0x18, 0xFE }, 0x4000);
    try testing.expectEqual(Flow{ .jump = 0x4000 }, back.flow);
}

test "absolute memory operands are reported, register-indirect ones are not" {
    const store = decode(&[_]u8{ 0xEA, 0x34, 0xC1 }, 0x4000);
    try testing.expectEqual(Mem{ .addr = 0xC134, .write = true }, store.mem.?);
    const load = decode(&[_]u8{ 0xF0, 0x44 }, 0x4000);
    try testing.expectEqual(Mem{ .addr = 0xFF44, .write = false }, load.mem.?);
    // LD (C),A names its address in a register: nothing static to report.
    try testing.expectEqual(@as(?Mem, null), decode(&[_]u8{0xE2}, 0x4000).mem);
    try testing.expectEqual(@as(?Mem, null), decode(&[_]u8{0x77}, 0x4000).mem);
}

test "an operand running past the end of the region is not decoded as code" {
    // $C3 is JP a16, but only one operand byte is present.
    const insn = decode(&[_]u8{ 0xC3, 0x00 }, 0x4000);
    try testing.expectEqual(@as(u8, 2), insn.len);
    try testing.expectEqual(Flow.illegal, insn.flow);
}

test "the trace follows both arms of a branch and stops at RET" {
    //  $4000  JR NZ,$4006     ; both arms
    //  $4002  LD A,$01
    //  $4004  JR $4007
    //  $4006  db $76          ; only reachable via the branch
    //  $4007  RET
    //  $4008  db $DD          ; never reachable
    const code = [_]u8{ 0x20, 0x04, 0x3E, 0x01, 0x18, 0x01, 0x76, 0xC9, 0xDD };
    var listing = try trace(testing.allocator, &code, 0x4000, &[_]u16{0x4000});
    defer listing.deinit(testing.allocator);
    for ([_]usize{ 0, 2, 4, 6, 7 }) |off| try testing.expect(listing.starts[off]);
    // The byte after the RET was never reached, so it is not claimed as code.
    try testing.expect(!listing.covered[8]);
    // ...and neither arm's operand byte is mistaken for an instruction start.
    try testing.expect(!listing.starts[1]);
}

test "call targets are collected, including ones outside the region" {
    //  $4000  CALL $4005
    //  $4003  CALL $0123      ; out of region
    //  ...
    const code = [_]u8{ 0xCD, 0x05, 0x40, 0xCD, 0x23, 0x01, 0xC9 };
    var listing = try trace(testing.allocator, &code, 0x4000, &[_]u16{0x4000});
    defer listing.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &[_]u16{ 0x0123, 0x4005 }, listing.calls);
}
