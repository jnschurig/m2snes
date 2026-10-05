//! The Game Boy side of the A/B: bank 4's writes, played by SameBoy's APU.
//!
//! Separate from `audioab.zig` because of what it links. SameBoy is vendored
//! and `vendor/` is not tracked, so this file cannot be compiled on a machine
//! that has not fetched it — and the rest of the A/B (what to ask for, how to
//! write the script, how to judge what came out) must still be in the gate's
//! unit tests there. What needs the C lives here; what does not, does not.
//!
//! The core is linked as it ships and fed through `GB_apu_write`, the same
//! entry point its own memory map calls when a game writes $FF10-$FF3F: see
//! `sbref.c` for the wrapper and for why the writes, rather than the ROM, are
//! what it is fed.

const std = @import("std");
const apu = @import("gb/apu.zig");
const harness = @import("gb/harness.zig");
const audiocost = @import("audiocost.zig");
const audio_req = @import("audio_req.zig");
const audioab = @import("audioab.zig");

/// T-cycles in a DMG frame, as `audioab` states it: the engine is called once
/// a frame, so this is how far apart two ticks are in the render.
const gb_frame_cycles: u32 = audioab.gb_frame_cycles;

/// SameBoy's APU, linked as it ships. See `sbref.c`.
const SbRef = opaque {};
extern fn sbref_new(sample_rate: c_uint) ?*SbRef;
extern fn sbref_free(self: ?*SbRef) void;
extern fn sbref_write(self: *SbRef, reg: u8, value: u8) void;
extern fn sbref_advance(self: *SbRef, cycles: u32, out: [*]i16, cap: usize) usize;
extern fn sbref_dropped(self: *SbRef) usize;
extern fn sbref_mute(self: *SbRef, channel: c_uint, muted: bool) void;

pub const GbError = error{
    /// A call into bank 4 did not return, which means the harness lost the
    /// engine rather than that the engine is wrong.
    DidNotReturn,
    /// SameBoy had samples the buffer could not take. Never a rounding detail:
    /// the render would be missing sound.
    SamplesDropped,
    OutOfMemory,
} || harness.Error;

/// Run the script through bank 4 and render what it played, interleaved stereo
/// at `rate`.
///
/// The run is `audiocmp.runGb`'s — a cold machine, `initializeAudio` once, then
/// each tick's ops and one `handleAudio` — with the writes fed to SameBoy as
/// they are made instead of being collected for comparison. Kept beside it
/// rather than folded into it on purpose: the comparison must not gain a
/// dependency on a renderer, and this must not gain the comparison's read-back
/// bookkeeping.
pub fn renderGb(
    gpa: std.mem.Allocator,
    rom: []const u8,
    script: audio_req.Script,
    rate: u32,
) GbError![]i16 {
    var m = try harness.bootFrom(gpa, rom, null);
    defer m.deinit();

    var log: std.ArrayList(apu.Write) = .empty;
    defer log.deinit(gpa);
    m.sys.bus.div_pin = 0;
    m.sys.bus.apu.log = &log;
    m.sys.bus.apu.allocator = gpa;
    defer m.sys.bus.apu.log = null;

    const s = sbref_new(rate) orelse return error.OutOfMemory;
    defer sbref_free(s);
    for (0..4) |c| sbref_mute(s, @intCast(c), false);

    // `initializeAudio`'s own writes, before the first tick and before any time
    // has passed. `audiocmp` starts its comparison after this call, because
    // both engines make these writes and neither's are in question — but a
    // render that skips them has an APU that was never powered on (NR52) at a
    // master volume of zero (NR50), and comes out silent. It did, which is how
    // this comment came to be here.
    if (!(try m.call(.{ .bank = audiocost.bank, .addr = audiocost.initialize })).returned)
        return error.DidNotReturn;
    for (log.items) |write| sbref_write(s, @truncate(write.addr), write.value);
    log.clearRetainingCapacity();

    var out: std.ArrayList(i16) = .empty;
    errdefer out.deinit(gpa);
    // A frame of stereo at any rate anyone asks for, with room to spare: the
    // callback fires on the APU's clock, not on ours, and a short buffer would
    // be a dropped sample rather than a short read.
    const buf = try gpa.alloc(i16, 1 << 14);
    defer gpa.free(buf);

    // Where the render has got to, in T-cycles from the first frame.
    var rendered: u64 = 0;

    // **A frame, not a tick, is what a frame of time is.** A script line is a
    // frame of the game, and it can carry no ticks at all (a lag frame, `-`) or
    // two. Advancing a frame per tick would play a lagging script fast and a
    // lag frame not at all — `test/audio/lag.req` exists precisely because the
    // game does this — so time is laid out by the script's frames, and the
    // ticks inside a frame keep the spacing the harness's own calls had.
    for (script.frames, 0..) |frame, frame_index| {
        const frame_start: u64 = @as(u64, frame_index) * gb_frame_cycles;
        var frame_base: ?u64 = null;

        for (frame) |ops| {
            const before = log.items.len;
            const base = absCycle(&m);
            if (frame_base == null) frame_base = base;
            for (ops) |op| switch (audio_req.slots[op.slot].kind) {
                .divider => m.sys.bus.div_pin = op.value,
                .request, .set, .game => m.write(audio_req.slots[op.slot].wram, op.value),
                .call => if (!(try m.call(.{ .bank = audiocost.bank, .addr = audio_req.slots[op.slot].wram })).returned)
                    return error.DidNotReturn,
            };
            if (!(try m.call(.{ .bank = audiocost.bank, .addr = audiocost.handle })).returned)
                return error.DidNotReturn;

            for (log.items[before..]) |write| {
                // Where inside its frame the write happened, measured from the
                // frame's first call. What the script cannot say is how far
                // apart two ticks of one frame really were on the Game Boy;
                // the harness's back-to-back calls are the only answer there
                // is, and they at least keep the order and the frame right. A
                // frame that somehow overran is clamped rather than allowed to
                // spill into the next one.
                const within = @min(write.cycle -| frame_base.?, gb_frame_cycles - 1);
                const at = frame_start + within;
                if (at > rendered) {
                    try advance(gpa, s, @intCast(at - rendered), buf, &out);
                    rendered = at;
                }
                sbref_write(s, @truncate(write.addr), write.value);
            }
            log.clearRetainingCapacity();
        }
    }

    // The last frame's own time, so a sound that ends on it is heard ending.
    const end: u64 = @as(u64, script.frames.len) * gb_frame_cycles;
    if (end > rendered) try advance(gpa, s, @intCast(end - rendered), buf, &out);

    if (sbref_dropped(s) != 0) return error.SamplesDropped;
    return out.toOwnedSlice(gpa);
}

fn advance(
    gpa: std.mem.Allocator,
    s: *SbRef,
    cycles: u32,
    buf: []i16,
    out: *std.ArrayList(i16),
) !void {
    // Walked in spans the buffer is sure to hold, so `sbref_advance` never has
    // more samples than room.
    const span: u32 = gb_frame_cycles / 2;
    var left = cycles;
    while (left > 0) {
        const take = @min(left, span);
        const n = sbref_advance(s, take, buf.ptr, buf.len);
        try out.appendSlice(gpa, buf[0..n]);
        left -= take;
    }
}

/// The harness's clock, unwrapped past the frame it is counted within.
fn absCycle(m: *const harness.Machine) u64 {
    return @as(u64, m.sys.bus.apu.frame) * gb_frame_cycles + m.sys.bus.apu.cycle;
}
