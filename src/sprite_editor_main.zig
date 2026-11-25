//! `zig build sprite-editor` (sprite-pixel-editor F6): the sprite editor, a
//! page served on a loopback port. It reads the ROM (`M2_ROM`), builds the
//! sprite model, prints the URL and serves until interrupted:
//!
//! - `GET /`, `GET /editor.js`: the page (`src/sprite_editor/`)
//! - `GET /api/model`: `{ model, state }`, the model and the data files as
//!   they are on disk now (`sprite_editor.modelJson`, `load`)
//! - `POST /api/save`: a `sprite_editor.State`, checked (`normalize`) and
//!   written to the three data files, each only if it changes
//!
//! It listens on 127.0.0.1 only and answers only requests whose `Host` (and
//! `Origin`, if sent) is that address (`sprite_editor.localRequest`).

const std = @import("std");
const build_options = @import("build_options");
const rom_mod = @import("rom.zig");
const snes_convert = @import("snes_convert.zig");
const sprite_model = @import("sprite_model.zig");
const editor = @import("sprite_editor.zig");

const index_html = @embedFile("sprite_editor/index.html");
const editor_js = @embedFile("sprite_editor/editor.js");

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    port: u16,
    model: *const sprite_model.Model,
    samus: []const bool,
    model_json: []const u8,
    rom_sha1: []const u8,
    /// Held over a request's reading or writing of the data files.
    lock: std.Io.Mutex = .init,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout.interface;

    if (build_options.rom_path.len == 0) {
        try out.print("sprite-editor: needs M2_ROM; see docs/setup.md\n", .{});
        try out.flush();
        std.process.exit(1);
    }
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, build_options.rom_path, a, .limited(rom_mod.expected_size * 4));
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(rom, &digest, .{});

    const set = try snes_convert.run(a, rom);
    const model = try a.create(sprite_model.Model);
    model.* = try sprite_model.build(a, rom, set.assets, &.{});
    const rom_sha1 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    var ctx: Ctx = .{
        .gpa = init.gpa,
        .io = io,
        .port = 0,
        .model = model,
        .samus = try editor.samusTiles(a, model),
        .model_json = try editor.modelJson(a, model, rom_sha1),
        .rom_sha1 = rom_sha1,
    };

    // The data files must parse before the page is offered.
    {
        var scratch = std.heap.ArenaAllocator.init(init.gpa);
        defer scratch.deinit();
        var why: []const u8 = "";
        _ = editor.load(scratch.allocator(), io, std.Io.Dir.cwd(), &why) catch |e| {
            try out.print("sprite-editor: {s}{s}{t}\n", .{ why, if (why.len > 0) ": " else "", e });
            try out.flush();
            std.process.exit(1);
        };
    }

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    ctx.port = server.socket.address.getPort();
    try out.print("sprite-editor: {d} tiles, {d} frames, {d} conflicts\nsprite-editor: http://127.0.0.1:{d}/\n", .{ model.tiles.len, model.frames.len, model.conflicts.len, ctx.port });
    try out.flush();

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const conn = try server.accept(io);
        group.concurrent(io, serve, .{ &ctx, conn }) catch serve(&ctx, conn);
    }
}

/// One connection's requests, until it closes.
fn serve(ctx: *Ctx, conn: std.Io.net.Stream) void {
    defer conn.close(ctx.io);
    var rb: [16 * 1024]u8 = undefined;
    var wb: [16 * 1024]u8 = undefined;
    var r = conn.reader(ctx.io, &rb);
    var w = conn.writer(ctx.io, &wb);
    var hs = std.http.Server.init(&r.interface, &w.interface);
    while (true) {
        var req = hs.receiveHead() catch return;
        handle(ctx, &req) catch |e| {
            std.log.err("{s} {s}: {t}", .{ @tagName(req.head.method), req.head.target, e });
            return;
        };
        if (!req.head.keep_alive) return;
    }
}

fn handle(ctx: *Ctx, req: *std.http.Server.Request) !void {
    var host: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
    }
    if (!editor.localRequest(host, origin, ctx.port)) return send(req, .forbidden, "text/plain", "sprite-editor: not a local request\n");

    const target = req.head.target;
    const get = req.head.method == .GET or req.head.method == .HEAD;
    if (get and std.mem.eql(u8, target, "/")) return send(req, .ok, "text/html; charset=utf-8", index_html);
    if (get and std.mem.eql(u8, target, "/editor.js")) return send(req, .ok, "text/javascript; charset=utf-8", editor_js);
    if (get and std.mem.eql(u8, target, "/api/model")) return apiModel(ctx, req);
    if (req.head.method == .POST and std.mem.eql(u8, target, "/api/save")) return apiSave(ctx, req);
    return send(req, .not_found, "text/plain", "not found\n");
}

fn send(req: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn sendJson(a: std.mem.Allocator, req: *std.http.Server.Request, status: std.http.Status, v: anytype) !void {
    return send(req, status, "application/json", try std.json.Stringify.valueAlloc(a, v, .{}));
}

fn apiModel(ctx: *Ctx, req: *std.http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const state = blk: {
        try ctx.lock.lock(ctx.io);
        defer ctx.lock.unlock(ctx.io);
        break :blk editor.load(a, ctx.io, std.Io.Dir.cwd(), &why) catch |e|
            return sendJson(a, req, .internal_server_error, .{ .@"error" = try std.fmt.allocPrint(a, "{s} {t}", .{ why, e }) });
    };
    const state_json = try std.json.Stringify.valueAlloc(a, state, .{});
    const body = try std.mem.concat(a, u8, &.{ "{\"model\":", ctx.model_json, ",\"state\":", state_json, "}" });
    return send(req, .ok, "application/json", body);
}

fn apiSave(ctx: *Ctx, req: *std.http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var ct_json = false;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) ct_json = std.mem.startsWith(u8, h.value, "application/json");
    }
    // A form post from another page can't set this content type.
    if (!ct_json) return sendJson(a, req, .unsupported_media_type, .{ .@"error" = "expected application/json" });
    var body_buf: [4096]u8 = undefined;
    const body_r = try req.readerExpectContinue(&body_buf);
    const body = try body_r.allocRemaining(a, .limited(32 << 20));

    const state = std.json.parseFromSliceLeaky(editor.State, a, body, .{}) catch |e|
        return sendJson(a, req, .bad_request, .{ .@"error" = try std.fmt.allocPrint(a, "save: {t}", .{e}) });
    var why: []const u8 = "";
    const n = editor.normalize(a, ctx.model, ctx.samus, state, &why) catch |e| switch (e) {
        error.BadSave => return sendJson(a, req, .bad_request, .{ .@"error" = why }),
        else => return e,
    };

    try ctx.lock.lock(ctx.io);
    defer ctx.lock.unlock(ctx.io);
    const dir = std.Io.Dir.cwd();
    const colors_src = try editor.readSource(a, ctx.io, dir, .colors);
    const files = [_]struct { f: editor.DataFile, bytes: []const u8 }{
        .{ .f = .colors, .bytes = try editor.patchColors(a, colors_src, n.colors) },
        .{ .f = .edits, .bytes = try editor.writeEdits(a, n.edits, ctx.rom_sha1) },
        .{ .f = .frames, .bytes = try editor.writeFrames(a, n.frames) },
    };
    var written: std.ArrayList([]const u8) = .empty;
    for (files) |x| {
        const old = try editor.readSource(a, ctx.io, dir, x.f);
        if (std.mem.eql(u8, old, x.bytes)) continue;
        try writeAtomic(ctx.io, dir, x.f, x.bytes);
        try written.append(a, x.f.path());
    }
    for (written.items) |p| std.log.info("saved {s}", .{p});
    return sendJson(a, req, .ok, .{ .written = written.items });
}

/// Writes one of the editor's own files (`editor.DataFile`, the only paths it
/// can name) through a temporary file, so a failed write leaves the old one.
fn writeAtomic(io: std.Io, dir: std.Io.Dir, f: editor.DataFile, bytes: []const u8) !void {
    var af = try dir.createFileAtomic(io, f.path(), .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}
