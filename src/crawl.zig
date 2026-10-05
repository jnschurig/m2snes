//! 1.0 Step 5a: the door crawler. Our Game Boy walks through every door that
//! has an opening, from the new game on, and records what each one loads.
//!
//! The ROM does not say which tileset about half the warp destinations are
//! drawn with: a door that loads only an enemy page, or only a lava table,
//! keeps the rest of whatever the room it leaves had. Which rooms a door can
//! be walked through from is what settles that, and the ROM's scroll bits say
//! only where the camera stops, not where a wall is. So the engine decides:
//! Samus is put beside the crossing and the pad walks her into it.

const std = @import("std");
const harness = @import("gb/harness.zig");
const probe = @import("gb/probe.zig");
const room = @import("room.zig");
const oracle_keys = struct {
    fn pad(right: bool, left: bool, up: bool, down: bool, jump: bool) probe.Buttons {
        var b: probe.Buttons = .{};
        if (right) b.dpad &= ~@as(u4, 0b0001);
        if (left) b.dpad &= ~@as(u4, 0b0010);
        if (up) b.dpad &= ~@as(u4, 0b0100);
        if (down) b.dpad &= ~@as(u4, 0b1000);
        if (jump) b.buttons &= ~@as(u4, 0b0001);
        return b;
    }
};

/// `$D808`-`$D814`: what a save keeps of the loaded state.
pub const block_addr: u16 = 0xD808;
pub const block_len: usize = warp.block_len;

const warp = @import("warp.zig");
const door = @import("door.zig");
const roster = @import("roster.zig");
const map = @import("map.zig");
const offsets = @import("offsets.zig");

// ---- What the crawl reads and writes on the Game Boy -------------------------

/// `samusItems`: the item bits the crawl gives her so that Hi-Jump, Space
/// Jump and the Screw Attack get her to any edge. Not the Spider Ball (bit 5):
/// a held Down with it on carries her up the nearest wall. Bit 7 is unused.
pub const items_addr: u16 = 0xD045;
pub const all_items: u8 = 0x5F;
/// `samusCurHealthLow` and its tanks, topped up every frame so acid, spikes
/// and enemies cannot end a crawl in a death.
pub const health_addr: u16 = room.cur_health_addr;
pub const tanks_addr: u16 = 0xD050;
/// `acidDamageValue` and `spikeDamageValue`, which `DAMAGE` writes.
pub const acid_addr: u16 = 0xD077;
pub const spike_addr: u16 = 0xD078;

/// `samusPrevYPixel`: a load writes it beside $FFC0 (00:$0CB0), and the
/// vertical move puts her back to it when a frame's move is refused.
pub const prev_y_addr: u16 = 0xD00C;

/// And a second copy of her pixel row that the next frame puts her back to:
/// found by writing each byte that held her old row and seeing which one made
/// a placement hold (the others did not).
pub const prev_y_frame_addr: u16 = 0xD029;

/// The background map the room is drawn into, and the tile `destroyBlock`
/// leaves where a block was (01:$5705).
pub const bg_map: u16 = 0x9800;
pub const cleared_tile: u8 = 0xFF;

/// What a crossing left loaded, read off the machine on arrival.
pub const Loaded = struct {
    block: [block_len]u8,
    acid: u8,
    spike: u8,

    pub fn read(m: *harness.Machine) Loaded {
        var l: Loaded = .{ .block = undefined, .acid = m.read(acid_addr), .spike = m.read(spike_addr) };
        for (&l.block, 0..) |*b, i| b.* = m.read(block_addr + @as(u16, @intCast(i)));
        return l;
    }

    /// As `warp.Tileset`, through the ROM's own pointer tables.
    pub fn tileset(self: Loaded, rom: []const u8) ?warp.Tileset {
        return warp.tilesetOfBlock(rom, self.block);
    }

    pub fn bank(self: Loaded) u8 {
        return self.block[9];
    }
};

/// Put Samus at `(y, x)` in `cell` of the bank the machine is in, with the
/// camera `warp.cameraFor` gives, and draw the screen. The loaded state is
/// left alone: that is what the crawl is measuring.
pub fn place(m: *harness.Machine, rom: []const u8, t: warp.Tileset, bank: u8, c: map.Cell, y: u16, x: u16) !void {
    const cy, const cx = warp.cameraFor(c, y, x);
    m.write(room.samus_pixel_y_addr, @truncate(y));
    m.write(prev_y_addr, @truncate(y));
    m.write(prev_y_frame_addr, @truncate(y));
    m.write(room.samus_screen_y_addr, @truncate(y >> 8));
    m.write(room.samus_pixel_x_addr, @truncate(x));
    m.write(room.samus_screen_x_addr, @truncate(x >> 8));
    m.write(room.camera_pixel_y_addr, @truncate(cy));
    m.write(room.camera_screen_y_addr, @truncate(cy >> 8));
    m.write(room.camera_pixel_x_addr, @truncate(cx));
    m.write(room.camera_screen_x_addr, @truncate(cx >> 8));
    m.write(room.direction_addr, 0);
    // `Machine.call` puts back the PC and nothing else, and a snapshot can be
    // taken mid-routine: resumed with its registers and ROM bank clobbered by
    // the draw, the game soft-resets two frames later. So all of it goes back.
    const cpu = m.sys.cpu;
    const high = m.sys.bus.cart.highBank();
    // And a frame boundary can find IME off (the OAM transfer in HRAM), where
    // the draw's frame waits would wait for a vblank that is never taken.
    m.sys.cpu.ime = true;
    try room.drawRoom(m, bank, c.y, c.x, 4_000_000);
    m.sys.cpu = cpu;
    m.setBank(@intCast(high));
    // And every destructible block in it cleared, as a player walking through
    // would have cleared it: the tile a destroyed block leaves.
    const coll = warp.collisionTable(rom, t.collision) orelse return;
    for (0..0x400) |i| {
        const at: u16 = bg_map + @as(u16, @intCast(i));
        const id = m.read(at);
        if (coll[id] & (warp.block_shot | warp.block_bomb) != 0) m.write(at, cleared_tile);
    }
    // Enemies are left where they are. Emptying their slots from here, with
    // the enemy pass part-way through one, soft-resets the game; the Screw
    // Attack and the health kept topped up see her past them instead.
}

fn topUp(m: *harness.Machine) void {
    m.write(items_addr, all_items);
    m.write(tanks_addr, 5);
    m.write(health_addr, 0x99);
    m.write(health_addr + 1, 5);
}

/// A crossing walked: the door the engine ran, and where it put her.
pub const Walked = struct {
    door: u16,
    dir: u8,
    frames: usize,
    bank: u8,
    cell: u8,
    loaded: Loaded,
};

/// `loadDoorIndex` (00:$0C37): what every edge trigger calls once it has set
/// the direction. It reads the camera cell's word out of the map bank's
/// transition table at $4300, clears bit 11 and owes the door (`$D08E`).
pub const load_door_index: u16 = 0x0C37;

/// `$D00E`'s value for each direction (see `room.Direction`).
fn code(dir: roster.Dir) u8 {
    return switch (dir) {
        .right => 1,
        .left => 2,
        .up => 4,
        .down => 8,
    };
}

/// Cross the edge `dir` leaves the camera's cell by, the way a trigger does:
/// the direction, then `loadDoorIndex`, and the main loop runs the door. Null
/// when no door ran.
/// The pad for one frame of walking at the edge `dir` leaves by: toward it,
/// with the jump held 32 frames in 36 -- a jump is as high as A is held --
/// which with Hi-Jump takes her up a step, over a lip or up a shaft. `dx` is how far the
/// opening is across from her, for the two vertical edges.
fn pad(dir: roster.Dir, f: usize, dx: i32) probe.Buttons {
    const jump = f % 36 < 32;
    return switch (dir) {
        .right => oracle_keys.pad(true, false, false, false, jump),
        .left => oracle_keys.pad(false, true, false, false, jump),
        .up => oracle_keys.pad(dx > 4, dx < -4, true, false, jump),
        .down => oracle_keys.pad(dx > 4, dx < -4, false, false, false),
    };
}

/// Walk from where she stands toward the opening in the edge `dir` leaves
/// by (`tx`, its pixel column in the cell), until a door runs or `budget`
/// frames pass. The engine decides both whether she gets there and what the
/// door loads. Null when no door ran.
pub fn walkThrough(m: *harness.Machine, dir: roster.Dir, tx: u16, budget: usize) !?Walked {
    var f: usize = 0;
    while (f < budget) : (f += 1) {
        topUp(m);
        const x: i32 = m.read(room.samus_pixel_x_addr);
        _ = try m.runFrames(1, pad(dir, f, @as(i32, tx) - x - 8));
        if (m.read(room.direction_addr) == 0) continue;
        const di = m.readWord(room.door_index_addr);
        var g: usize = 0;
        while (g < 900 and m.read(room.direction_addr) != 0) : (g += 1) {
            topUp(m);
            _ = try m.runFrames(1, .{});
        }
        if (m.read(room.direction_addr) != 0) return null;
        // Read at once: left to play on, she can fall straight into the next
        // door down before the crawl has looked.
        const p = room.placement(m);
        const got: Walked = .{
            .door = di,
            .dir = code(dir),
            .frames = f,
            .bank = m.read(room.map_bank_addr),
            .cell = (p.screen_row << 4) | p.screen_col,
            .loaded = Loaded.read(m),
        };
        // Then a few frames for the fade to finish, with her held where she
        // came in, so the snapshot is of a room at rest.
        for (0..30) |_| {
            topUp(m);
            m.write(room.samus_pixel_y_addr, p.pixel_y);
            m.write(prev_y_addr, p.pixel_y);
            m.write(prev_y_frame_addr, p.pixel_y);
            m.write(room.samus_screen_y_addr, p.screen_row);
            m.write(room.samus_pixel_x_addr, p.pixel_x);
            m.write(room.samus_screen_x_addr, p.screen_col);
            _ = try m.runFrames(1, .{});
            if (m.read(room.direction_addr) != 0) return null;
        }
        return got;
    }
    return null;
}

// ---- The crawl ---------------------------------------------------------------

/// A room with a loaded state the crawl can stand in, and the machine there.
pub const Entry = struct {
    bank: u8,
    room: u16,
    cell: u8,
    loaded: Loaded,
    snap: harness.Snapshot,
    /// Walked into from the new game through doors the engine ran, rather
    /// than seeded from the static reading (`warp.Inference`).
    truth: bool,
};

/// A door the engine ran with Samus walked into it: out of `from`'s room at
/// `cell` going `dir`, at Metroid count `count`, into `to`.
pub const Edge = struct { from: usize, cell: u8, dir: roster.Dir, count: u8, walked: Walked, to: usize };

pub const Crawl = struct {
    entries: std.ArrayList(Entry) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    /// Doors tried from somewhere and never walked through.
    tried: usize = 0,
    no_spot: usize = 0,
    stuck: usize = 0,
    walled: usize = 0,
    undrawn: usize = 0,
    seeded: usize = 0,

    pub fn deinit(self: *Crawl, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*n| n.snap.deinit(allocator);
        self.entries.deinit(allocator);
        self.edges.deinit(allocator);
    }
};

/// `metroidCountReal` and the count the HUD shows.
pub const count_real_addr: u16 = 0xD089;
pub const count_shown_addr: u16 = 0xD09A;
/// The room mode in the Queen's room (`!QUEEN_ROOM`, 00:$2C81): entered by
/// `ENTER_QUEEN` and left only by `EXIT_QUEEN`, so not crawled out of.
pub const room_mode_addr: u16 = 0xD08B;
pub const queen_room: u8 = 0x11;

pub var verbose = false;

const Key = struct { room: u16, tileset: warp.Tileset };

/// What a door try counts when it walks nowhere. Kept apart from `Crawl` so
/// that each of the crawl's lanes keeps its own, and they are summed after.
const Tally = struct {
    no_spot: usize = 0,
    stuck: usize = 0,
    undrawn: usize = 0,

    fn add(self: *Tally, o: Tally) void {
        self.no_spot += o.no_spot;
        self.stuck += o.stuck;
        self.undrawn += o.undrawn;
    }
};

/// Try one door: Samus stood beside it in the machine as `e` left it, at
/// `count`, and walked through. The spots one or two tiles from the edge
/// first, then the middle of the screen. Nothing but `e` and the arguments
/// decides the answer -- every spot starts from `e.snap` -- so any machine
/// can try any door.
fn tryDoor(m: *harness.Machine, rom: []const u8, w: roster.World, e: Entry, ci: u8, d: roster.Dir, count: u8, out: *Tally) !?Walked {
    const t = e.loaded.tileset(rom) orelse return null;
    const here: roster.Place = .{ .bank = e.bank, .cell = ci };
    const c = w.cellOf(here);
    const b = warp.body(rom, w, here) orelse return null;
    var buf: [3]warp.Spot = undefined;
    var spots: [4]warp.Spot = undefined;
    var n: usize = 0;
    for (warp.spotsNear(rom, b, t, d, &buf)) |sp| {
        spots[n] = sp;
        n += 1;
    }
    if (warp.standingSpotThrough(rom, b, t, 128, 128, true)) |sp| {
        spots[n] = sp;
        n += 1;
    }
    if (n == 0) {
        out.no_spot += 1;
        return null;
    }
    for (spots[0..n], 0..) |sp, i| {
        m.restore(e.snap);
        m.write(count_real_addr, count);
        m.write(count_shown_addr, count);
        place(m, rom, t, e.bank, c, (@as(u16, c.y) << 8) | sp.y, (@as(u16, c.x) << 8) | sp.x) catch |err| switch (err) {
            error.RoomDidNotDraw => {
                out.undrawn += 1;
                continue;
            },
            else => return err,
        };
        // Near the door, a short walk; from the middle, a longer one.
        const budget: usize = if (i + 1 < n or n == 1) 150 else 360;
        if (try walkThrough(m, d, @as(u16, sp.x) + 8, budget)) |g| return g;
    }
    out.stuck += 1;
    return null;
}

/// One door to try: out of entry `entry` at `cell` going `dir`, at `count`.
const Door = struct { entry: usize, cell: u8, dir: roster.Dir, count: u8 };

/// The crawl's bookkeeping, which only ever runs on one thread: the queue,
/// what has a place in it, and the seeding of the rooms nothing walked into.
const Queue = struct {
    allocator: std.mem.Allocator,
    rom: []const u8,
    w: roster.World,
    inf: warp.Inference,
    opts: Options,
    out: *Crawl,
    seen: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    reached: std.AutoHashMapUnmanaged(u16, void) = .empty,
    seed_bank: usize = 0,
    seed_cell: usize = 0,

    fn deinit(q: *Queue) void {
        q.seen.deinit(q.allocator);
        q.reached.deinit(q.allocator);
    }

    /// Entry `head` about to be crawled out of: reported, and false for the
    /// Queen's room, which is not.
    fn open(q: *Queue, m: *harness.Machine, head: usize) bool {
        if (q.opts.progress) |p| p(.{ .done = head, .queued = q.out.entries.items.len, .doors = q.out.edges.items.len });
        m.restore(q.out.entries.items[head].snap);
        return m.read(room_mode_addr) != queen_room;
    }

    /// Every door out of entry `head`, in the order the crawl tries them.
    fn doors(q: *Queue, head: usize, list: *std.ArrayList(Door)) !void {
        const e = q.out.entries.items[head];
        const w = q.w;
        const bi = e.bank - map.first_bank;
        for (0..map.cells) |ci| {
            const c = w.banks[bi].cells[ci];
            if (!c.inUse() or w.room[bi][ci] != e.room) continue;
            const index = roster.doorIndex(c.transition);
            var tb: [8]u8 = undefined;
            const ths = q.inf.thresholdsOf(index, &tb);
            for ([_]roster.Dir{ .right, .left, .up, .down }) |d| {
                if (!d.blocks(c.scroll)) continue;
                // At the new game's count, and at every count the door
                // tests against: a door that branches may go elsewhere.
                // Only where the branch sends the door somewhere else: what
                // it loads at another count, the warp's chain works out at
                // the live count on both machines.
                try list.append(q.allocator, .{ .entry = head, .cell = @intCast(ci), .dir = d, .count = warp.start_count });
                const to0 = q.inf.warpsTo(index, warp.start_count);
                for (ths) |th| {
                    if (std.meta.eql(q.inf.warpsTo(index, th), to0)) continue;
                    try list.append(q.allocator, .{ .entry = head, .cell = @intCast(ci), .dir = d, .count = th });
                }
            }
        }
    }

    /// File what trying `tried` walked into (null: nothing). `snap.take()`
    /// hands over the machine as it arrived, and is asked only when the
    /// arrival is new to the queue. Every walked door, in the order
    /// tried, goes through here, so the entries and edges do not depend on
    /// where the tries ran.
    fn file(q: *Queue, tried: Door, walked: ?Walked, snap: anytype) !void {
        const out = q.out;
        const rom = q.rom;
        const w = q.w;
        const d = tried.dir;
        const ci = tried.cell;
        out.tried += 1;
        var g = walked orelse return;
        const e = out.entries.items[tried.entry];
        const tg = g.loaded.tileset(rom) orelse return;
        // Where she came in: the next cell over for door 0,
        // which runs nothing; otherwise the cell the warp named,
        // or the one past it when that is blank or walled on the
        // side she enters by (`roster.world`'s rule).
        var there: roster.Place = .{ .bank = g.bank, .cell = g.cell };
        if (g.door == 0) there = .{ .bank = e.bank, .cell = d.step(ci).? };
        if (!w.cellOf(there).inUse() or !warp.enteringOpen(rom, w, there, d, tg)) {
            const on: roster.Place = .{ .bank = there.bank, .cell = d.step(there.cell).? };
            if (w.cellOf(on).inUse() and warp.enteringOpen(rom, w, on, d, tg)) there = on;
        }
        if (!w.cellOf(there).inUse()) {
            out.walled += 1;
            return;
        }
        g.bank = there.bank;
        g.cell = there.cell;
        const r = warp.roomAt(w, there);
        if (r == e.room and g.door == 0) return;
        const gop = try q.seen.getOrPut(q.allocator, .{ .room = r, .tileset = tg });
        if (!gop.found_existing) {
            gop.value_ptr.* = out.entries.items.len;
            // Truth when walked from truth, or through a door
            // that loads a whole tileset of its own.
            const truth = e.truth or (g.door != 0 and q.inf.loadsTileset(g.door, tried.count));
            try out.entries.append(q.allocator, .{ .bank = g.bank, .room = r, .cell = g.cell, .loaded = g.loaded, .snap = try snap.take(), .truth = truth });
            try q.reached.put(q.allocator, r, {});
        }
        try out.edges.append(q.allocator, .{ .from = tried.entry, .cell = ci, .dir = d, .count = tried.count, .walked = g, .to = gop.value_ptr.* });
        if (verbose) std.debug.print("  {X}:{X:0>2} {s} @{X}: door {X} -> {X}:{X:0>2}{s}\n", .{ e.bank, ci, @tagName(d), tried.count, g.door, g.bank, g.cell, if (e.truth) "" else " (from a seed)" });
    }

    /// Dry: seed the next room nobody walked into, bank then cell order.
    /// False when there is none left.
    fn seed(q: *Queue, m: *harness.Machine, base: harness.Snapshot) !bool {
        const w = q.w;
        while (q.seed_bank < map.bank_count) {
            while (q.seed_cell < map.cells) : (q.seed_cell += 1) {
                const c = w.banks[q.seed_bank].cells[q.seed_cell];
                const r = w.room[q.seed_bank][q.seed_cell];
                if (!c.inUse() or q.reached.contains(r)) continue;
                const p: roster.Place = .{ .bank = map.first_bank + @as(u8, @intCast(q.seed_bank)), .cell = @intCast(q.seed_cell) };
                const l = q.inf.loader(p) orelse continue;
                m.restore(base);
                _ = room.spawn(m, .{ .map_bank = p.bank, .screen_row = c.y, .screen_col = c.x, .door_index = l }) catch continue;
                const lo = Loaded.read(m);
                const t = lo.tileset(q.rom) orelse continue;
                try q.reached.put(q.allocator, r, {});
                const gop = try q.seen.getOrPut(q.allocator, .{ .room = r, .tileset = t });
                if (gop.found_existing) continue;
                gop.value_ptr.* = q.out.entries.items.len;
                try q.out.entries.append(q.allocator, .{ .bank = p.bank, .room = r, .cell = p.cell, .loaded = lo, .snap = try m.snapshot(), .truth = false });
                q.out.seeded += 1;
                q.seed_cell += 1;
                return true;
            }
            q.seed_bank += 1;
            q.seed_cell = 0;
        }
        return false;
    }
};

/// The snapshot `Queue.file` takes of a machine that has just walked in.
const TakeFrom = struct {
    m: *harness.Machine,
    fn take(s: TakeFrom) !harness.Snapshot {
        return s.m.snapshot();
    }
};

/// One that a lane already took, handed over.
const Taken = struct {
    snap: *?harness.Snapshot,
    fn take(s: Taken) !harness.Snapshot {
        defer s.snap.* = null;
        return s.snap.*.?;
    }
};

/// A door tried on a lane: what it walked into, and the machine as it came
/// in. The snapshot is taken whether or not the door turns out to be new to
/// the queue (only the merge knows), and freed there when it is not.
const Tried = struct {
    door: Door,
    walked: ?Walked = null,
    snap: ?harness.Snapshot = null,
    err: ?anyerror = null,
};

/// The crawl's worker threads, each with a Game Boy of its own. `count` of
/// them, the first run on the calling thread.
const Lanes = struct {
    machines: []harness.Machine,
    tallies: []Tally,

    fn init(allocator: std.mem.Allocator, base: harness.Snapshot, count: usize) !Lanes {
        const machines = try allocator.alloc(harness.Machine, count);
        var made: usize = 0;
        errdefer {
            for (machines[0..made]) |*m| m.deinit();
            allocator.free(machines);
        }
        while (made < count) : (made += 1) machines[made] = try harness.Machine.fromSnapshot(allocator, base);
        const tallies = try allocator.alloc(Tally, count);
        @memset(tallies, .{});
        return .{ .machines = machines, .tallies = tallies };
    }

    fn deinit(self: *Lanes, allocator: std.mem.Allocator) void {
        for (self.machines) |*m| m.deinit();
        allocator.free(self.machines);
        allocator.free(self.tallies);
    }

    const Ctx = struct {
        rom: []const u8,
        w: roster.World,
        entries: []const Entry,
        tries: []Tried,
        next: std.atomic.Value(usize) = .init(0),
    };

    fn go(ctx: *Ctx, m: *harness.Machine, tally: *Tally) void {
        while (true) {
            const i = ctx.next.fetchAdd(1, .monotonic);
            if (i >= ctx.tries.len) return;
            const t = &ctx.tries[i];
            const e = ctx.entries[t.door.entry];
            t.walked = tryDoor(m, ctx.rom, ctx.w, e, t.door.cell, t.door.dir, t.door.count, tally) catch |err| {
                t.err = err;
                continue;
            };
            if (t.walked != null) t.snap = m.snapshot() catch |err| {
                t.err = err;
                continue;
            };
        }
    }

    /// Try every door in `tries`, spread across the lanes.
    fn run(self: *Lanes, rom: []const u8, w: roster.World, entries: []const Entry, tries: []Tried) !void {
        var ctx: Ctx = .{ .rom = rom, .w = w, .entries = entries, .tries = tries };
        const n = @min(self.machines.len, tries.len);
        if (n == 0) return;
        var threads: [max_jobs]std.Thread = undefined;
        var spawned: usize = 0;
        defer for (threads[0..spawned]) |t| t.join();
        while (spawned + 1 < n) : (spawned += 1) {
            threads[spawned] = try std.Thread.spawn(.{}, go, .{ &ctx, &self.machines[spawned + 1], &self.tallies[spawned + 1] });
        }
        go(&ctx, &self.machines[0], &self.tallies[0]);
    }
};

/// The most lanes a crawl runs.
pub const max_jobs = 64;

/// Every door out of every room, tried with Samus beside it. Rooms are
/// crawled breadth first from the new game, in what the doors walked leave
/// loaded; when that runs dry, a room not yet reached is seeded with what the
/// static reading says it has, and the crawl goes on from there.
///
/// With more than one job (release Step 4), the queue is taken a wave at a
/// time -- every entry pending when the wave starts -- and the wave's doors
/// are tried across the lanes, then filed on this thread in the order one
/// machine would have tried them. The entries, edges and counters are the
/// one-machine crawl's (`verify-full`'s `crawl jobs` rung holds that).
pub fn crawl(allocator: std.mem.Allocator, rom: []const u8, w: roster.World, inf: warp.Inference, opts: Options) !Crawl {
    var out: Crawl = .{};
    errdefer out.deinit(allocator);
    var q: Queue = .{ .allocator = allocator, .rom = rom, .w = w, .inf = inf, .opts = opts, .out = &out };
    defer q.deinit();

    var m = try room.bootIntoPlay(allocator, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{}); // the appearance
    var base = try m.snapshot();
    defer base.deinit(allocator);
    {
        const l = Loaded.read(&m);
        const p = room.placement(&m);
        const cell = (p.screen_row << 4) | p.screen_col;
        const r = warp.roomAt(w, .{ .bank = l.bank(), .cell = cell });
        try out.entries.append(allocator, .{ .bank = l.bank(), .room = r, .cell = cell, .loaded = l, .snap = try m.snapshot(), .truth = true });
        try q.seen.put(allocator, .{ .room = r, .tileset = l.tileset(rom).? }, 0);
        try q.reached.put(allocator, r, {});
    }

    const jobs = opts.lanes();
    var lanes: ?Lanes = if (jobs > 1) try Lanes.init(allocator, base, jobs) else null;
    defer if (lanes) |*l| l.deinit(allocator);
    var tally: Tally = .{};
    var list: std.ArrayList(Door) = .empty;
    defer list.deinit(allocator);
    var tries: std.ArrayList(Tried) = .empty;
    defer tries.deinit(allocator);

    var head: usize = 0;
    while (true) {
        if (lanes) |*ls| {
            while (head < out.entries.items.len) {
                // The wave: every entry pending now. What they walk into
                // waits for the next.
                const end = out.entries.items.len;
                list.clearRetainingCapacity();
                for (head..end) |h| if (q.open(&m, h)) try q.doors(h, &list);
                tries.clearRetainingCapacity();
                for (list.items) |d| try tries.append(allocator, .{ .door = d });
                defer for (tries.items) |*t| if (t.snap) |*s| s.deinit(allocator);
                try ls.run(rom, w, out.entries.items, tries.items);
                for (tries.items) |*t| {
                    if (t.err) |err| return err;
                    try q.file(t.door, t.walked, Taken{ .snap = &t.snap });
                }
                head = end;
            }
        } else {
            while (head < out.entries.items.len) : (head += 1) {
                if (!q.open(&m, head)) continue;
                list.clearRetainingCapacity();
                try q.doors(head, &list);
                for (list.items) |d| {
                    const g = try tryDoor(&m, rom, w, out.entries.items[head], d.cell, d.dir, d.count, &tally);
                    try q.file(d, g, TakeFrom{ .m = &m });
                }
            }
        }
        if (!try q.seed(&m, base)) break;
    }
    if (lanes) |l| for (l.tallies) |t| tally.add(t);
    out.no_spot = tally.no_spot;
    out.stuck = tally.stuck;
    out.undrawn = tally.undrawn;
    return out;
}

/// Where the crawl is, for a progress line: `done` of `queued` rooms-with-a-
/// state crawled out of so far (the queue grows as doors find new ones).
pub const Status = struct { done: usize, queued: usize, doors: usize };

pub const Options = struct {
    /// Called before each room-with-a-state is crawled out of.
    progress: ?*const fn (Status) void = null,
    /// Lanes to try doors on: 0 is one per logical CPU, 1 the crawl on one
    /// machine, which is the reference the others are held to.
    jobs: usize = 0,

    fn lanes(o: Options) usize {
        const n = if (o.jobs != 0) o.jobs else std.Thread.getCpuCount() catch 1;
        return @min(n, max_jobs);
    }
};

/// What `walk` found: the doors, and the crawl's counters, which a crawl
/// split across threads must reproduce exactly.
pub const Walk = struct {
    doors: []warp.WalkedDoor,
    entries: usize,
    tried: usize,
    no_spot: usize,
    stuck: usize,
    walled: usize,
    undrawn: usize,
    seeded: usize,
};

/// The whole crawl from a ROM: the world, the inference, the crawl and its
/// doors (release Step 3). `doors` is allocated with `allocator`; everything
/// else is freed before it returns.
pub fn walk(allocator: std.mem.Allocator, rom: []const u8, opts: Options) !Walk {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const w = try roster.world(a, rom);
    const inf = try warp.Inference.init(a, rom, w);
    const c = try crawl(a, rom, w, inf, opts);
    return .{
        .doors = try walkedDoors(allocator, c),
        .entries = c.entries.items.len,
        .tried = c.tried,
        .no_spot = c.no_spot,
        .stuck = c.stuck,
        .walled = c.walled,
        .undrawn = c.undrawn,
        .seeded = c.seeded,
    };
}

/// The crawl as the warp table reads it: every door walked, both ends.
pub fn walkedDoors(allocator: std.mem.Allocator, c: Crawl) ![]warp.WalkedDoor {
    const out = try allocator.alloc(warp.WalkedDoor, c.edges.items.len);
    for (c.edges.items, out) |e, *o| {
        const f = c.entries.items[e.from];
        const t = c.entries.items[e.to];
        o.* = .{
            .from = .{ .bank = f.bank, .cell = e.cell },
            .from_room = f.room,
            .from_truth = f.truth,
            .from_block = f.loaded.block,
            .dir = e.dir,
            .count = e.count,
            .door = e.walked.door,
            .to = .{ .bank = e.walked.bank, .cell = e.walked.cell },
            .to_room = t.room,
            .to_truth = t.truth,
            .to_block = e.walked.loaded.block,
        };
    }
    return out;
}

const testing = std.testing;
const testrom = @import("testrom");

fn newGame(a: std.mem.Allocator, rom: []const u8) !harness.Snapshot {
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{});
    return m.snapshot();
}

test "a placement holds, and the first door from the new game is walked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rom = try testrom.load(a) orelse return error.SkipZigTest;
    var w = try roster.world(a, rom);
    defer w.deinit(a);
    var m = try room.bootIntoPlay(a, rom);
    defer m.deinit();
    _ = try m.runFrames(300, .{});
    const l = Loaded.read(&m);
    const t = l.tileset(rom).?;
    // Where the appearance leaves her standing is a standing spot: the
    // geometry `warp.standingSpot` reads off the tables is the engine's.
    {
        const p = room.placement(&m);
        const at: roster.Place = .{ .bank = 0xF, .cell = (p.screen_row << 4) | p.screen_col };
        const sp = warp.standingSpot(rom, warp.body(rom, w, at).?, t, @as(u16, p.pixel_y) + 10, @as(u16, p.pixel_x) + 8).?;
        try testing.expectEqual(p.pixel_y, sp.y);
    }
    const here: roster.Place = .{ .bank = 0xF, .cell = 0x77 };
    const c = w.cellOf(here);
    var buf: [3]warp.Spot = undefined;
    const spots = warp.spotsNear(rom, warp.body(rom, w, here).?, t, .right, &buf);
    try testing.expect(spots.len > 0);
    const sp = spots[0];
    try place(&m, rom, t, 0xF, c, (@as(u16, c.y) << 8) | sp.y, (@as(u16, c.x) << 8) | sp.x);
    _ = try m.runFrames(3, .{});
    // She is where she was put: the second copy of her row was written.
    try testing.expectEqual(sp.y, m.read(room.samus_pixel_y_addr));
    const g = (try walkThrough(&m, .right, @as(u16, sp.x) + 8, 150)).?;
    // Door $1DF, out of the landing site's east edge into bank A.
    try testing.expectEqual(@as(u16, 0x1DF), g.door);
    try testing.expectEqual(@as(u8, 0x0A), g.bank);
    try testing.expect(g.loaded.tileset(rom) != null);
    // And a wall is not a door: the landing site's west edge at $F:$75 is
    // rock, and walking her into it runs nothing.
    m.restore(try newGame(a, rom));
    const west: roster.Place = .{ .bank = 0xF, .cell = 0x75 };
    const wc = w.cellOf(west);
    const ws = warp.standingSpotThrough(rom, warp.body(rom, w, west).?, t, 128, 16, true).?;
    try place(&m, rom, t, 0xF, wc, (@as(u16, wc.y) << 8) | ws.y, (@as(u16, wc.x) << 8) | ws.x);
    try testing.expect(try walkThrough(&m, .left, @as(u16, ws.x) + 8, 150) == null);
}
