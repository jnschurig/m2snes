//! The cart build as one call (release Step 3): the user's ROM and its crawl
//! in, the `.sfc` and its symbol file out, in memory. No file is read or
//! written here, so the player's binary and `zig build rom` run the same path.

const std = @import("std");
const convert = @import("snes_convert.zig");
const inject = @import("snes_inject.zig");
const screen = @import("snes_screen.zig");
const warp = @import("warp.zig");

pub const Options = struct {
    /// The debug cart: `DebugAllowed` set, so L+R+Start in play opens the
    /// debug menu (1.0 Step 2b).
    debug: bool = false,
    /// The door crawl for this ROM: `crawl.walk`'s doors, or the cached file.
    walked: []const warp.WalkedDoor,
    /// Filled when the inject fails on a layout budget.
    diag: ?*inject.Diagnosis = null,
};

pub const Output = struct {
    /// The cart; `rom.bytes` is the `.sfc`.
    rom: inject.Rom,
    /// The symbol file Mesen2 loads and Step 14's correspondence map reads.
    sym: []u8,
    /// What the cart was built from, for the dev step's report and previews.
    set: convert.Set,
    boot: screen.Boot,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Output) void {
        self.rom.deinit();
        self.allocator.free(self.sym);
        self.set.deinit();
    }
};

pub fn build(gpa: std.mem.Allocator, rom_bytes: []const u8, opts: Options) !Output {
    var set = try convert.runWalked(gpa, rom_bytes, opts.walked);
    errdefer set.deinit();
    // **The shipped cart boots on the game's own new game, and has since Step
    // 7.** `newGameBoot` reads the landing site, the camera, the facing
    // direction and the appearance sequence's length out of the cartridge --
    // `initial_save` and the four instructions that end `loadGame_samusData` --
    // so the cart a person picks up starts where the game starts. `chooseBoot`
    // is still what the rungs use: it searches for a cell some door states
    // outright, which is the right thing for a gate and the wrong thing for a
    // player.
    //
    // Either way the screen is chosen from the ROM and not from the converted
    // set, because the choice rests on `screens.assign` -- the thing that knows
    // which door script stated a screen's tileset.
    const boot = try screen.newGameBoot(gpa, rom_bytes);

    var scratch: inject.Diagnosis = .{};
    var rom = try inject.build(gpa, set, boot, opts.diag orelse &scratch);
    errdefer rom.deinit();
    if (opts.debug) try inject.enableDebug(&rom);

    // Built in memory and handed back whole, so a caller writing files never
    // leaves a half-written .sym beside a complete .sfc.
    var sym: std.Io.Writer.Allocating = .init(gpa);
    errdefer sym.deinit();
    try inject.writeSymbols(rom, &sym.writer);

    return .{ .rom = rom, .sym = try sym.toOwnedSlice(), .set = set, .boot = boot, .allocator = gpa };
}
