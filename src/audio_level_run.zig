//! The level check's renders: each of `audio_level.cases` on both engines.
//!
//! The same two renders `audioab` makes, into `build-out/audio-level/` so a
//! failing level can be listened to, and kept out of `audioab`'s directory so a
//! gate run does not overwrite what somebody was listening to there. Links
//! SameBoy through `audioab_render.zig`, so only `audioab level` and a gate
//! built with `vendor/sameboy` present reach it.

const std = @import("std");
const aram_image = @import("aram_image.zig");
const audio_req = @import("audio_req.zig");
const audiocmp = @import("audiocmp.zig");
const audioab = @import("audioab.zig");
const audioab_render = @import("audioab_render.zig");
const audio_level = @import("audio_level.zig");
const wav = @import("wav.zig");

pub const out_dir = "build-out/audio-level";
/// For a caller that must say it did not run rather than fail.
pub const spcrun_path = audiocmp.spcrun_path;
const gb_rate: u32 = 44100;

pub const Error = error{ RenderFailed, SpcrunFailed, BadScript };

/// Render every case and measure it. `why` names the case and the step that
/// failed when this returns an error.
///
/// Every `spcrun` at once, and the Game Boy renders while they run: the cases
/// share nothing but the image, so together they cost about the longest of
/// them, which is how the gate's boot fault sweep runs too. Only the WAV is
/// wanted, so `spcrun`'s trace goes nowhere.
pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    engine: []const u8,
    why: *[]const u8,
) ![audio_level.cases.len]audio_level.Measured {
    const n = audio_level.cases.len;
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);

    const img = try aram_image.build(arena, rom, engine, .hosted);
    const image_path = out_dir ++ "/aram.bin";
    try dir.writeFile(io, .{ .sub_path = "aram.bin", .data = img.bytes });

    var scripts: [n]audio_req.Script = undefined;
    var stems: [n][]const u8 = undefined;
    var snes_paths: [n][]const u8 = undefined;
    var children: [n]?std.process.Child = @splat(null);
    defer for (&children) |*slot| if (slot.*) |*c| c.kill(io);

    for (audio_level.cases, 0..) |c, i| {
        why.* = c.name;
        const text = switch (c.what) {
            .ask => |a| blk: {
                const buf = try arena.alloc(u8, 64);
                stems[i] = a.stem(buf);
                break :blk try audioab.scriptText(arena, a);
            },
            .script => |p| blk: {
                const base = std.fs.path.basename(p);
                stems[i] = base[0 .. base.len - ".req".len];
                break :blk try cwd.readFileAlloc(io, p, arena, .limited(64 << 20));
            },
        };
        var line: usize = 0;
        var what: []const u8 = "";
        scripts[i] = audio_req.parse(arena, text, &line, &what) catch return error.BadScript;

        const spc_script = try std.fmt.allocPrint(arena, "{s}/{s}.spcrun.txt", .{ out_dir, stems[i] });
        {
            var buf: [1 << 16]u8 = undefined;
            var file = try cwd.createFile(io, spc_script, .{});
            defer file.close(io);
            var w = file.writer(io, &buf);
            try audio_req.writeSpcrunScript(scripts[i], &w.interface);
            try w.interface.flush();
        }
        snes_paths[i] = try std.fmt.allocPrint(arena, "{s}/{s}.snes.wav", .{ out_dir, stems[i] });
        children[i] = std.process.spawn(io, .{
            .argv = &.{ audiocmp.spcrun_path, "--image", image_path, "--ack-delay", "0", "--wav", snes_paths[i], spc_script },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return error.SpcrunFailed;
    }

    var ms: [n]audio_level.Measured = undefined;
    for (audio_level.cases, 0..) |c, i| {
        why.* = c.name;
        const gb = audioab_render.renderGb(gpa, rom, scripts[i], gb_rate) catch return error.RenderFailed;
        defer gpa.free(gb);
        var wav_bytes: std.ArrayList(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(arena, &wav_bytes);
        try wav.write(&w.writer, gb, gb_rate);
        try dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}.gb.wav", .{stems[i]}), .data = w.written() });
        ms[i].gb_ms = audio_level.meanSquare(gb);
    }

    for (audio_level.cases, 0..) |c, i| {
        why.* = c.name;
        var child = children[i].?;
        children[i] = null;
        const term = child.wait(io) catch return error.SpcrunFailed;
        if (term != .exited or term.exited != 0) return error.SpcrunFailed;
        // What `spcrun` wrote, and not an array of ours: it is another process,
        // and the file is what anyone will listen to.
        const bytes = try cwd.readFileAlloc(io, snes_paths[i], arena, .limited(1 << 30));
        const parsed = try wav.parse(bytes);
        const snes = try arena.alloc(i16, parsed.samples.len);
        for (parsed.samples, 0..) |v, k| snes[k] = v;
        ms[i].snes_ms = audio_level.meanSquare(snes);
    }
    return ms;
}

/// The report both callers print: one line per case, then the verdict.
pub fn report(out: *std.Io.Writer, ms: []const audio_level.Measured, indent: []const u8) !?audio_level.Verdict {
    for (audio_level.cases, ms) |c, m| {
        try out.print("{s}{s:<20} Game Boy RMS {d:>6.0}, cart {d:>6.0}: {s}{d:.1} dB\n", .{
            indent, c.name, m.gbRms(), m.snesRms(), sign(m.db()), @abs(m.db()),
        });
    }
    return audio_level.grade(ms) catch |e| {
        try out.print("{s}no verdict: {s}\n", .{ indent, @errorName(e) });
        return null;
    };
}

/// `std.fmt` has no plus flag, and a level is read by its sign.
pub fn sign(x: f64) []const u8 {
    return if (x < 0) "-" else "+";
}
