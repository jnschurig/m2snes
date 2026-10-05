//! The enemy AI oracle: an AI graded against the Game Boy running the same AI.
//!
//! Step 12f ports the nine AIs James's recording dispatches (`docs/slice.md`),
//! and "the AI is in `AiTable`" says only that an enemy is handed to a routine.
//! Every other rung here compares Samus. So this one compares an enemy.
//!
//! **Both machines are handed the same slot, not the same spawn walk.** The
//! loader has its own rungs, and it only loads a record as a camera edge
//! crosses it -- `room.zig` measured 240 frames of a standing Samus loading
//! nothing -- so a comparison that waited for it would be grading the camera.
//! Instead each case puts Samus in a cell the AI lives in, settles her on the
//! Game Boy, builds the cart's boot record from where she settled, and then at
//! the same point of the same tick writes one slot on each machine: exactly the
//! bytes `loadOneEnemy` (03:$422F) would have written for that cell's spawn
//! record under that camera. Every other slot is emptied on both.
//!
//! **What is compared is the slot's history per pass, not per frame.** The
//! enemy pass acts on every other frame on both machines, and which parity it
//! lands on is a property of when each was booted, not of the AI. So each
//! machine's per-frame record is reduced to its runs of identical records and
//! the two reductions are compared entry by entry. An AI that holds a state for
//! longer on one machine than the other shows up as a different entry; a pass
//! landing one frame later does not.
//!
//! **One byte is handed across rather than graded**: the coin an Alpha's hurt
//! reaction tosses on `rDIV`. See `Coin`.
//!
//! **Twenty-eight globals are graded beside the slots** (Step 13d, Step 14's two, 1.0 Step 8b's
//! three of slot 0's, 1.0 Step 12's seven of the blob thrower's, 1.0 Step 13's four of
//! Arachnus's, 1.0 Step 14's Gamma stun counter, 1.0 Step 15's Zeta's and 1.0 Step 16's three
//! of the Omega's), because a Metroid fight
//! keeps its state in them and a kill is only visible there: the counts, the post-death timer,
//! the fight flag. A beam's hit is the same kind of state: slot 0's stun, ice counter and
//! health. So is the blob thrower, whose state and rewritten part list are the ROM's globals
//! and not its slot's. Each global's history is collapsed on its own, for the reason `passes`
//! collapses each slot on its own. See `globals`.
//!
//! **The cart writes a record only when it differs from the last one**, with
//! the tick it landed on, and `runCart` holds the previous record across the
//! gap. Nothing is lost -- the comparison collapses repeats anyway -- and it is
//! what lets a case outlive one save file's worth of frames: a kill is fought,
//! exploded and then waited out for $90 timer steps.
//!
//! The rung is shown failing on every run rather than once: `fault` rebuilds
//! each case's cart with the AI's `AiTable` row blanked, and a case whose
//! faulted cart still matches is a case that grades nothing.

const std = @import("std");
const harness = @import("gb/harness.zig");
const room = @import("room.zig");
const oracle = @import("oracle.zig");
const entity = @import("entity.zig");
const offsets = @import("offsets.zig");
const snes_screen = @import("snes_screen.zig");
const snes_trace = @import("snes_trace.zig");
const inject = @import("snes_inject.zig");
const convert = @import("snes_convert.zig");
const roster = @import("roster.zig");

pub const Error = error{
    NoSuchCell,
    NoRecordWithAi,
    NeverSettled,
    LateHitMissed,
    MissingSymbol,
    NoSaveFile,
    ShortSaveFile,
    NotTheImage,
    /// More changed records than one save file holds: see `max_cart_entries`.
    TooManyRecords,
    OutOfMemory,
};

/// One AI and a room it lives in. The room is the census's: where the
/// recording first dispatched the AI.
pub const Case = struct {
    name: []const u8,
    /// The AI's Game Boy address in bank 2, which is also its `AiTable` key.
    ai: u16,
    /// Map bank `$9`-`$F` and cell, `row * 16 + col`.
    bank: u8,
    cell: u8,
    /// How many ticks each machine runs after the seed.
    frames: u16 = 300,
    /// The spawn flag a child of slot 0 carries: `$00`, slot 0's link, for the
    /// objects that tell their parent when they die, and `$06` for projectiles
    /// that do not. See `childOfSlot0`.
    child_flag: u8 = 0x00,
    /// Projectile contacts to hand slot 0, as the hitbox test leaves them. An
    /// AI that reacts only to being shot is an AI no-input run never exercises.
    hits: []const Hit = &.{},
    /// The fewest distinct entries slot 0's Game Boy history may have. A missile
    /// door has a dozen in its whole life; everything else is held to twenty.
    min_passes: usize = min_passes,
    /// The Metroid count the room is booted at, as the game stores it; null is
    /// the new game's (release Step 0). A lava room's level is chosen by the
    /// count, and at the new game's some are flooded where the recording meets
    /// their enemies dry, so a case there boots at the recording's count.
    count: ?u8 = null,
    /// Pixels to move Samus's start from the cell's centre, before she settles.
    /// An Alpha picks its lunge from where she stands, so one spot grades one
    /// angle; the Step 13c cases stand her in more than one.
    samus_dx: i16 = 0,
    /// **Step 19: the camera, driven on both machines to the same schedule.**
    /// Empty leaves it to the game, which is every case before Step 19.
    ///
    /// A case with a sweep grades a different mechanism from the ones above: not
    /// what an AI does, but what happens to a *slot* when the screen leaves it
    /// and comes back -- `DeactivateOffscreen`, `DeleteOffscreen`,
    /// `ReactivateOffscreen` and the spawn walk that reloads the record. None of
    /// those moves unless the camera does, and the camera does not move unless
    /// something drives it: `room.zig` measured 240 frames of a standing Samus
    /// loading nothing. So the fixture writes the camera itself, a fixed number
    /// of pixels a tick, on the Game Boy and on the cart at the same point of
    /// the same tick -- the same class of lever as the slot seed and the hit
    /// record, and the same one `room.sweepCameraX` already pulls.
    ///
    /// **Samus goes with it**, because the camera is hers: left where she was,
    /// `HandleCamera` pulls the camera back on the next frame and the sweep
    /// fights the engine instead of driving it.
    sweep: []const Leg = &.{},
    /// **Step 19: the room reset a transition asks for, at this tick.** The
    /// enemy pass services the request by emptying every slot and putting the
    /// saved half of the spawn flags out to its bank's window and the new room's
    /// back in -- `ResetEntities`, 02:$418C plus $4217. Writing the request is
    /// the lever `room.zig` already pulls for the same reason: the harness's
    /// `WARP` does not go through the door interpreter, so nothing else raises
    /// it. The cart's byte is `!SpawnReload`; the Game Boy's are *two*, and both
    /// are raised here -- see the write itself in `runGb` for which and why.
    ///
    /// **It is the reset and not a crossing**, deliberately. A real transition
    /// would put a door script's ninety frames between the two machines, and
    /// what this grades is what the reset does to a live Metroid's flag -- the
    /// one step of a crossing that decides whether the record can come back.
    ///
    /// **Two ticks, not one, and the second is the one that grades anything.**
    /// The out-pass is skipped entirely while `previousLevelBank` is zero
    /// (02:$419D), and it is zero until a reset sets it -- so a case that fired
    /// one reset graded the load-in against a boot-filled buffer and nothing
    /// else. Measured: with `$04`'s translation to `$FE` deleted from
    /// `ResetEntities`, which is the defect this case exists to catch, a
    /// single-reset case still passed. The first reset is the room the player
    /// came from; the second is the one whose flag has to survive.
    resets: []const u16 = &.{},
    /// **Step 19: follow the record, not the slot index.** Every case above
    /// grades slot 0, because slot 0 is the one the seed fills and nothing takes
    /// it away. A case whose enemy *leaves* cannot: the delete empties the slot
    /// and the next record the walk loads -- a neighbour, on its own AI -- lands
    /// in it, so from then on the comparison is grading that neighbour under a
    /// hand-driven camera. Measured on `alpha2 reload`: sprite $5C arrived in
    /// slot 0 three passes after the Metroid left and its counter ran on the
    /// Game Boy and not on the cart.
    ///
    /// With this set the record compared is whichever of the sixteen slots holds
    /// this case's *spawn number*, or all-$FF when none does -- which is the
    /// question the mechanism asks: is the record live, and under what flag.
    /// Slots 1-3 are filled with $FF, so `childOfSlot0` never fires.
    by_number: bool = false,
    /// **Step 19: Samus frozen, on both machines, for every tick of a sweep.**
    /// `$C463` (`!Cutscene`) is what a Metroid's intro raises to hold her still,
    /// and it is raised here for the same reason a cutscene does: a sweep writes
    /// the camera, the camera is hers, and a thawed Samus dragged sideways by
    /// hand walks into terrain. Measured without it: `crawler away` reloaded its
    /// record a pixel apart in Y on the two machines, with the camera's Y
    /// differing on 400 of 560 frames and the sweep only ever writing X -- her
    /// physics, not the despawn window. The one case that was green without it
    /// (`alpha reload`) was green *because* the hatching Alpha's intro had frozen
    /// her already.
    ///
    /// What this gives up is named: an AI gated on the cutscene flag runs its
    /// frozen arm here. The AI rung above grades the others; this one grades
    /// whether the record survives leaving the screen.
    freeze: bool = false,
    /// **1.0 Step 8b: a second fault, on the mechanism the case is about.**
    /// Blanking the `AiTable` row is every case's fault, and for a case about a
    /// beam it proves only that the enemy runs. This patch -- bytes over the
    /// engine at a label, as the loadout segments' faults are -- breaks the
    /// behaviour itself, and the cart it builds must differ too: in a slot's
    /// history or in a global's.
    behaviour: ?oracle.Patch = null,
    /// **1.0 Step 11: a divider read, handed across rather than graded.** The
    /// drivel tosses `rDIV`'s low nibble for when to start looking for Samus
    /// (02:$5AEA), and the port reads its divider clock, `!DivClock`, in its
    /// place -- which nothing makes agree with a real divider, for the reason
    /// `Coin` gives. So the Game Boy's run records the byte each read took,
    /// where the instruction after it starts, and the cart's script writes the
    /// same byte into `!DivClock`'s high byte as its own read is about to run,
    /// in the same order. What the toss *decides* is still graded.
    ///
    /// **A list since 1.0 Step 12**: the gunzoo tosses at two sites, one per
    /// patrol, and each site's reads are handed across in that site's order.
    dividers: []const Divider = &.{},
    /// **1.0 Step 13: B held, on both machines, over these ticks.** Arachnus
    /// curls up while the Game Boy's B is held (02:$521B) -- the one AI that
    /// reads the pad -- and a rung that stands Samus still never shows it. The
    /// press is real input, not a byte written: the Game Boy steps the tick
    /// with the key down, and the cart is handed it on the poll the segment
    /// rung's relation names (`oracle.writeLua`'s `hold`), so Samus fires too,
    /// on both machines.
    ///
    /// **Any key since 1.0 Step 21** (`Span.key`, B unless named): the baby
    /// Metroid eats a block only when its chase drives it into one, so Samus
    /// has to get past the block first, and she walks and jumps there by the
    /// same real input. Spans that overlap press their keys together.
    fire: []const Span = &.{},
    /// **1.0 Step 21: the map graded at the last tick, in the view.** What the
    /// baby Metroid does to a block (`baby_clearBlock`, 02:$7D97) is written to
    /// the tilemap and nowhere in a slot or a global, so a case about it
    /// compares the two maps where the Game Boy's camera ends, as the seed's
    /// terrain is compared where it begins. The behaviour fault counts it too.
    tiles_end: bool = false,
};

/// Ticks `from` up to, not including, `to`, with `key` held.
pub const Span = struct { from: u16, to: u16, key: oracle.Key = oracle.key.fire };

/// The keys `spans` hold on `tick`, together.
fn pressed(spans: []const Span, tick: usize) oracle.Key {
    var k: u8 = 0;
    for (spans) |sp| if (tick >= sp.from and tick < sp.to) {
        k |= @bitCast(sp.key);
    };
    return @bitCast(k);
}

/// See `Case.divider`. `gb_pc` is the bank-2 address the CPU's PC holds as
/// the read's operand comes off the bus -- the instruction after the read;
/// `cart` is the engine label of the port's read.
pub const Divider = struct { gb_pc: u16, cart: []const u8 };
pub const max_divs: usize = 512;
pub const max_div_sites: usize = 2;

/// The Game Boy's side of `Case.dividers`: every `rDIV` read made from each
/// site's `pc`, per site. A bus read watch rather than the harness's execution
/// watch, because the oracle steps the system directly and the execution watch
/// sees only calls.
const DivWatch = struct {
    m: *harness.Machine,
    pcs: []const Divider,
    vals: [max_div_sites][max_divs]u8 = undefined,
    n: [max_div_sites]usize = .{0} ** max_div_sites,
    fn read(ctx: *anyopaque, bus: *const @import("gb/bus.zig").Bus, addr: u16, value: u8) void {
        const self: *DivWatch = @ptrCast(@alignCast(ctx));
        if (addr != 0xFF04) return;
        if (bus.cart.highBank() != 2) return;
        for (self.pcs, 0..) |d, i| {
            if (self.m.sys.cpu.pc != d.gb_pc or self.n[i] == max_divs) continue;
            self.vals[i][self.n[i]] = value;
            self.n[i] += 1;
        }
    }
};

/// The cart's side: the sites its script watches, and the values to hand each.
pub const DivHand = struct {
    sites: [max_div_sites]u32 = .{0} ** max_div_sites,
    vals: [max_div_sites][]const u8 = .{&.{}} ** max_div_sites,
    n: usize = 0,
};

/// One stretch of a `Case.sweep`: `dx` pixels of camera a tick, `ticks` times.
pub const Leg = struct { dx: i16, ticks: u16 };

/// One contact: before tick `tick`, both machines are given the record
/// `collision_projectileEnemies` would have left -- the weapon, slot 0 as the
/// enemy, and the direction -- at the same point of the same tick. **It is the
/// lever `snes boot`'s damage phase pulls**, and it is sound for the same
/// reason: the record persists until the enemy pass reaches the slot it names
/// and hands it on (02:$438F), so the tick's parity does not decide whether it
/// lands.
pub const Hit = struct {
    tick: u16,
    weapon: u8,
    dir: u8,
    /// **1.0 Step 17: written after Samus's own contact test, not at the top of
    /// the tick.** The frame tests her against the enemies (00:$32AB) before
    /// the shots and bombs (00:$0698, $08FE), and her touch writes the same
    /// byte, so a hit written at the logic point is overwritten by it whenever
    /// she is touching the enemy -- a larva on her is, every frame. A bomb's
    /// test comes after hers in the original, so a late hit lands where it does:
    /// at 00:$0538 on the Game Boy and `MainLoop_afterContact` on the cart.
    late: bool = false,
};

/// **The one thing a hit does that this rung hands across instead of grading.**
/// A missile that hurts an Alpha -- or a Gamma, 02:$70AF and $70F8, since 1.0
/// Step 14 -- picks its knockback on one axis from the side
/// the shot came from, and on the other from `rDIV`'s low bit (02:$6D2F and
/// $6D54) -- the Game Boy's free-running divider, which the port substitutes
/// with `!EnFrame` (`AlphaCoin`) and which nothing can make agree with a real
/// divider. So the Game Boy's run records the bit it tossed, as the knockback
/// flags it set, and the cart is handed those flags on the pass its own hurt
/// lands, before anything reads them. The *deterministic* axis is not handed
/// across -- only `mask` is -- so a wrong push on the side the shot came from
/// still differs. Whether the substitute's coin comes up both ways is
/// `snes boot`'s to grade.
pub const Coin = struct { mask: u8, value: u8 };
/// Twelve since 1.0 Step 14: a Gamma takes ten missiles, and the ninth and
/// tenth went unrecorded at eight, so the cart tossed its own. Twenty-four
/// since 1.0 Step 15: a Zeta takes twenty.
pub const max_coins: usize = 24;

/// The knockback flags a hurt's coin writes, from the direction the shot was
/// travelling, in the order 02:$6D0D tests it: right and left push
/// horizontally and toss for a vertical flag, down and up the other way.
pub fn coinMask(dir: u8) u8 {
    if (dir & 0x01 != 0) return 0x0A;
    if (dir & 0x08 != 0) return 0x05;
    if (dir & 0x02 != 0) return 0x0A;
    return 0x05;
}

pub const cases = [_]Case{
    // The census first dispatches it with Samus in `$A:$44`; the record is the
    // next screen's, loaded as the camera's right edge crossed into it.
    .{ .name = "hopper", .ai = 0x61DB, .bank = 0xA, .cell = 0x45 },
    // Both crawlers where the recording first meets them, on its way down.
    .{ .name = "crawlerA", .ai = 0x57DE, .bank = 0xF, .cell = 0x6A },
    .{ .name = "crawlerB", .ai = 0x58DE, .bank = 0xF, .cell = 0x6B },
    // A second room for crawler A, because the first walks straight off the
    // screen and never turns. This one turns on 149 of its 150 passes. `$C:$21`
    // was tried first and is not usable yet: the cart's camera moves where the
    // Game Boy's does not -- see `docs/bug_tracker.md`, 2026-09-13.
    .{ .name = "crawlerA corners", .ai = 0x57DE, .bank = 0xA, .cell = 0x0A },
    // 1.0 Step 18c: the room is drawn with the lava caves' tables now, which
    // our Game Boy walked in with, not caveFirst. From the centre she stands
    // where the camera leaves the icicle below the view, and it runs one pass.
    .{ .name = "rockIcicle", .ai = 0x5542, .bank = 0xA, .cell = 0x54, .samus_dx = 0x20 },
    // The census meets it with Samus in `$9:$E5`; the record is next door.
    .{ .name = "gullugg", .ai = 0x5CE0, .bank = 0x9, .cell = 0xE6 },
    // Not where the recording meets it (`$B:$13`): that record hangs below the
    // screen and is deactivated before its AI runs. This room goes through all
    // three states.
    .{ .name = "chuteLeech", .ai = 0x5E0B, .bank = 0x9, .cell = 0xC9 },
    .{ .name = "pipeBug", .ai = 0x5F67, .bank = 0xB, .cell = 0x17 },
    // A room where the mask is in view, so its fireball flies (77 passes) rather
    // than being deactivated on its first -- `$D:$3B`, where the recording first
    // meets one, hangs the mask above the screen.
    .{ .name = "wallfire", .ai = 0x62B4, .bank = 0xD, .cell = 0x4C, .child_flag = 0x06 },
    .{ .name = "wallfire shot", .ai = 0x62B4, .bank = 0xD, .cell = 0x4C, .child_flag = 0x06, .frames = 320, .hits = &.{.{ .tick = 250, .weapon = 0x01, .dir = 0x01 }} },
    // Four beams, five missiles from the right and one from the left after it
    // has gone: the plinks, the count, the blast's side, and the explosion.
    .{ .name = "missileDoor", .ai = 0x6A14, .bank = 0xE, .cell = 0x6A, .min_passes = 10, .hits = &.{
        .{ .tick = 10, .weapon = 0x00, .dir = 0x01 },
        .{ .tick = 20, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 30, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 40, .weapon = 0x03, .dir = 0x01 },
        .{ .tick = 50, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 60, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 70, .weapon = 0x08, .dir = 0x02 },
    } },
    // Step 13c. The census meets the hatching Alpha with Samus in `$F:$11`; its
    // record is next door, in `$F:$10`, where she stands in range from the start:
    // the flash, the freeze, the eight flashes, the rise, and the first lunges.
    // Seven hundred frames because 32 KiB of save RAM held no more of them;
    // the case cart has had 64 since 1.0 Step 8b (`cart_sram_bytes`).
    .{ .name = "hatchingAlpha", .ai = 0x6BB2, .bank = 0xF, .cell = 0x10, .frames = 700 },
    // The plain Alpha, in `$E:$B2` and not `$E:$07` where the census meets it:
    // from the middle of `$E:$07` Samus is never within `!ALPHA_RANGE`, and this
    // rung stands her still. Three spots, because the lunge's angle is where she
    // stands: straight below it -- which pins it against the ceiling on the
    // cardinal "up" -- and to either side. A fourth to the right, $30 over,
    // puts the cart's camera somewhere the Game Boy's is not.
    .{ .name = "alpha", .ai = 0x6C44, .bank = 0xE, .cell = 0xB2, .frames = 600 },
    .{ .name = "alpha left", .ai = 0x6C44, .bank = 0xE, .cell = 0xB2, .frames = 600, .samus_dx = -0x30 },
    .{ .name = "alpha right", .ai = 0x6C44, .bank = 0xE, .cell = 0xB2, .frames = 600, .samus_dx = 0x18 },
    // And shot: a beam's dink, four missiles from four directions that stun,
    // blink and knock it back without killing it, and a screw attack.
    .{ .name = "alpha shot", .ai = 0x6C44, .bank = 0xE, .cell = 0xB2, .frames = 600, .samus_dx = -0x30, .hits = &.{
        .{ .tick = 40, .weapon = 0x00, .dir = 0x01 },
        .{ .tick = 80, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 160, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 240, .weapon = 0x08, .dir = 0x08 },
        .{ .tick = 320, .weapon = 0x10, .dir = 0x01 },
        .{ .tick = 400, .weapon = 0x08, .dir = 0x04 },
    } },
    // Step 13d: the two kills, each at the recording's own ticks -- the frames
    // `zig build gbtrace -- kills` saw `enemy_weaponType` take each shot, less
    // the frame the fight started, plus the tick this case's fight starts on.
    // Each runs through the explosion, the slot's deletion and the post-death
    // timer's $90 steps, which is what the write-on-change record is for.
    //
    // Alpha 2, the plain one in `$E:$07`: the fight at 72 894, a beam at +2, and
    // missiles at +86 from the left and +144, +344, +440 and +496 from below --
    // the last is the kill. Graded in `$E:$B2` from `alpha shot`'s spot, for the
    // reason `alpha` is; this case's fight starts on tick 0.
    .{ .name = "alpha kill", .ai = 0x6C44, .bank = 0xE, .cell = 0xB2, .frames = 840, .samus_dx = -0x30, .hits = &.{
        .{ .tick = 2, .weapon = 0x00, .dir = 0x01 },
        .{ .tick = 86, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 144, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 344, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 440, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 496, .weapon = 0x08, .dir = 0x04 },
    } },
    // Alpha 1, the hatching one, in its own room: the fight at 16 265 and five
    // missiles at +288, +354 and +414 from below, +511 from the left and +623
    // from below. This case's fight starts on tick 270, after the intro.
    .{ .name = "hatchingAlpha kill", .ai = 0x6BB2, .bank = 0xF, .cell = 0x10, .frames = 1240, .hits = &.{
        .{ .tick = 270 + 288, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 270 + 354, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 270 + 414, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 270 + 511, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 270 + 623, .weapon = 0x08, .dir = 0x04 },
    } },
    // 1.0 Step 8b, the beams against ordinary enemies. The damage is
    // `weaponDamageTable` (02:$43C8): power 1, wave 4, spazer 8, plasma 30;
    // the ice beam does its own, two, and freezes.
    //
    // The moheek of `crawlerA corners` (health 5), frozen once: the counter's
    // climb, the blink from $C4, and the thaw at $D0 back into the crawl. The
    // behaviour fault stops the climb, so it never thaws.
    .{ .name = "crawlerA ice", .ai = 0x57DE, .bank = 0xA, .cell = 0x0A, .frames = 600, .hits = &.{
        .{ .tick = 20, .weapon = 0x01, .dir = 0x01 },
    }, .behaviour = .{ .label = "EnemyAnimateIce_climb", .bytes = &.{ 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA } } },
    // Frozen three times, 5 to 3 to 1 to 0 -- the second decrement skipped on
    // the way to zero -- and left: it thaws at no health and dies where it
    // hangs (02:$5683), with no explosion and no drop. Seventeen distinct
    // passes, not twenty: a frozen enemy is still but for its blink, and a
    // dead one is gone.
    .{ .name = "crawlerA ice kill", .ai = 0x57DE, .bank = 0xA, .cell = 0x0A, .frames = 600, .min_passes = 15, .hits = &.{
        .{ .tick = 20, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 60, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 100, .weapon = 0x01, .dir = 0x01 },
    }, .behaviour = .{ .label = "EnemyAnimateIce_climb", .bytes = &.{ 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA } } },
    // A Ramulken (health 12), shielded on the right, the left and below
    // (`$B0`): the power beam from the right plinks, and the wave beam from
    // the same side goes through the shield (02:$43AC), 12 to 8 to 4 to dead.
    // The behaviour fault makes the wave beam test the shield like any other.
    .{ .name = "hopper wave", .ai = 0x61DB, .bank = 0x9, .cell = 0x21, .frames = 400, .hits = &.{
        .{ .tick = 20, .weapon = 0x00, .dir = 0x01 },
        .{ .tick = 60, .weapon = 0x02, .dir = 0x01 },
        .{ .tick = 100, .weapon = 0x02, .dir = 0x01 },
        .{ .tick = 140, .weapon = 0x02, .dir = 0x01 },
    }, .behaviour = .{ .label = "EnemyCheckShields_waveTest", .bytes = &.{0x80} } },
    // An Autoad (health 14, no shields): the spazer takes it to 6 and kills it
    // with the second; the plasma's 30 kills it outright. Its even health
    // leaves a missile drop, half the time.
    //
    // **The killing ticks are chosen, and for the drop's roll.** 02:$56ED
    // tosses `rDIV`'s bit 0 for whether the corpse drops anything, and the
    // port tosses `!EnFrame`'s (see `EnemyAnimateExplosion`): a substitution,
    // since the SNES has no free-running divider. Both flip every pass, and
    // the divider runs at about 274.3 counts a frame, so the two agree for a
    // few passes and then disagree for a few. Measured, the plasma's single
    // shot agrees at ticks 21-24, 33-35; the spazer's second at 67-71, 77-81.
    // These are ticks where both machines *drop*, so the drop's blink and
    // expiry (`EnemyAnimateDrop`) are graded too. A fault in the roll's
    // polarity would still show: it flips both ticks' answers on the cart
    // alone.
    .{ .name = "hopper spazer", .ai = 0x61DB, .bank = 0xE, .cell = 0x82, .frames = 300, .hits = &.{
        .{ .tick = 20, .weapon = 0x03, .dir = 0x01 },
        .{ .tick = 67, .weapon = 0x03, .dir = 0x01 },
    } },
    .{ .name = "hopper plasma", .ai = 0x61DB, .bank = 0xE, .cell = 0x82, .frames = 300, .hits = &.{
        .{ .tick = 23, .weapon = 0x04, .dir = 0x01 },
    } },
    // 1.0 Step 11, the first batch of ordinary AIs, each in the room of its
    // first spawn record (`zig build roster`).
    .{ .name = "skreek", .ai = 0x59C7, .bank = 0xB, .cell = 0x54, .frames = 400 },
    // The drivel's coin is handed across: see `Case.divider`.
    // **1.0 Step 18c:** the room is drawn with the lava caves' tables, which
    // our Game Boy walked in with at the new game's count. There the camera
    // stays on the room's left clamp and the drivel flies off the right of
    // the view in seven passes, wherever she stands, so the camera is carried
    // after it, a pixel a tick for 96: 191 passes, its acid for 128. At two
    // pixels a tick the Game Boy moves the acid a pass late at tick 82, which
    // looks like the `rLY` budget's deferral (`docs/bug_tracker.md`,
    // 2026-09-13), and is not graded here.
    .{ .name = "drivel", .ai = 0x5AE2, .bank = 0xB, .cell = 0x51, .sweep = &.{.{ .dx = 1, .ticks = 96 }}, .frames = 400, .dividers = &.{.{ .gb_pc = 0x5AED, .cart = "EnAiDrivel_coin" }} },
    .{ .name = "moto", .ai = 0x66F3, .bank = 0xB, .cell = 0x62 },
    .{ .name = "gravitt", .ai = 0x695F, .bank = 0x9, .cell = 0x97, .frames = 400 },
    .{ .name = "flittVanishing", .ai = 0x68A0, .bank = 0xB, .cell = 0xF5 },
    // Two rooms: the first weaves through all four states and both speeds
    // before leaving the screen, the second turns off a wall on the far-medium
    // probe.
    .{ .name = "halzyn", .ai = 0x6746, .bank = 0x9, .cell = 0x67, .frames = 400 },
    .{ .name = "halzyn turn", .ai = 0x6746, .bank = 0x9, .cell = 0x69, .frames = 400 },
    .{ .name = "septogg", .ai = 0x6841, .bank = 0xB, .cell = 0x24 },
    .{ .name = "flittMoving", .ai = 0x68FC, .bank = 0xB, .cell = 0xF1, .frames = 500 },
    // 1.0 Step 12, the second batch, each in a room of one of its spawn records
    // (`zig build roster -- ai <addr>`). Four are not the first record's room,
    // and a Samus offset is where she settles relative to the cell's centre:
    // - proboscum, `$9:$7D` $18 left: from the centre the Game Boy's camera dips
    //   three pixels every 52 frames and the cart's does not -- not the AI's,
    //   and filed in `docs/bug_tracker.md`;
    // - skorpVert, `$A:$C7` and not `$B:$9B`, where the cart's camera scrolls
    //   down $1B pixels and the Game Boy's holds (filed with it);
    // - autrack, `$E:$82` $30 right, the flipped turret ($41): `$D:$53`'s record
    //   hangs below the screen, `$E:$74`'s too, and `$E:$64` never settles;
    // - autom, `$E:$B7` $30 left: from `$E:$B5` it walks off the screen in
    //   twenty passes. The flame's toss is handed across: see `Case.dividers`.
    .{ .name = "glowFly", .ai = 0x54A1, .bank = 0xC, .cell = 0xCB, .frames = 400 },
    .{ .name = "proboscum", .ai = 0x65D5, .bank = 0x9, .cell = 0x7D, .samus_dx = -0x18, .frames = 400 },
    // Both skorps' room is a lava room (`$A:$C6`-`$D7`), flooded through door
    // $073 at the new game's count. The recording meets it drained (table 6)
    // at $12-$14 (`src/recorded_tables.txt`), so both boot at $14, where $073
    // drains it on the Game Boy too ($12 floods it again: its count gates are
    // not in order). skorpVert stands still for the whole run with Samus at the
    // cell's centre; $30 to the right of it, it moves (measured).
    .{ .name = "skorpVert", .ai = 0x60AB, .bank = 0xA, .cell = 0xC7, .count = 0x14, .samus_dx = 0x30 },
    .{ .name = "skorpHori", .ai = 0x60F8, .bank = 0xA, .cell = 0xD6, .count = 0x14 },
    .{ .name = "autrack", .ai = 0x6145, .bank = 0xE, .cell = 0x82, .samus_dx = 0x30, .frames = 400 },
    .{ .name = "autom", .ai = 0x6540, .bank = 0xE, .cell = 0xB7, .samus_dx = -0x30, .frames = 500, .dividers = &.{.{ .gb_pc = 0x654C, .cart = "EnAiAutom_coin" }} },
    // Both patrols' tosses are handed across.
    .{ .name = "gunzoo", .ai = 0x638C, .bank = 0xE, .cell = 0x6B, .frames = 600, .dividers = &.{
        .{ .gb_pc = 0x63AE, .cart = "EnAiGunzoo_coinVertical" },
        .{ .gb_pc = 0x6449, .cart = "EnAiGunzoo_coinHorizontal" },
    } },
    // Its state is global: see `globals`' last seven.
    .{ .name = "blobThrower", .ai = 0x4EA1, .bank = 0x9, .cell = 0x1B, .frames = 600 },
    // A missile from the right. Samus is moved off the block: standing on it,
    // her touch ($20) is the contact every pass and overwrites the missile.
    // **1.0 Step 18c:** the room is drawn with the lava caves' tables, which
    // our Game Boy walked in with, not caveFirst. Under those it takes 24
    // entries, five states and two turns. Samus is $10 right of the centre:
    // from $30 left the camera leaves the block above the view, and from $10
    // or $20 left the view crosses into `$A:$76`, which the Game Boy's
    // reference does not draw (`room.spawn` draws the boot cell whole).
    .{ .name = "missileBlock", .ai = 0x6622, .bank = 0xA, .cell = 0x77, .samus_dx = 0x10, .min_passes = 8, .hits = &.{
        .{ .tick = 24, .weapon = 0x08, .dir = 0x02 },
    } },
    // 1.0 Step 13: Arachnus, in its room, from the recording's opening shot
    // (part 07 frame 1 097, the ice beam from the right): off the pedestal
    // and bouncing, stood up, and spitting a fireball whenever the last is
    // gone -- two in 400 frames. **Samus is frozen** (`freeze`): unfrozen, the
    // fireballs knock her back, her camera moves every frame, and the Game
    // Boy's `rLY` budget deferring the fireball's deletion by a frame (tick
    // 302; `docs/bug_tracker.md`, 2026-09-13, accepted) lands on a pass whose
    // positions differ. Arachnus never reads the cutscene flag.
    .{ .name = "arachnus", .ai = 0x5109, .bank = 0xD, .cell = 0xC0, .frames = 400, .freeze = true, .hits = &.{
        .{ .tick = 10, .weapon = 0x01, .dir = 0x02 },
    } },
    // B tapped, then held for 100 ticks: it curls up, rolls towards Samus
    // along the middle table and the low one, stands, and curls again while
    // B is still down -- past her, so it turns. The behaviour fault ignores B.
    .{ .name = "arachnus roll", .ai = 0x5109, .bank = 0xD, .cell = 0xC0, .frames = 600, .freeze = true, .hits = &.{
        .{ .tick = 10, .weapon = 0x01, .dir = 0x02 },
    }, .fire = &.{ .{ .from = 300, .to = 302 }, .{ .from = 420, .to = 520 } }, .behaviour = .{ .label = "EnAiArachnus_fireTest", .bytes = &.{ 0x80, 0x00 } } },
    // The six bombs, at the recording's own spacing: part 07 frames 3 102,
    // 3 112, 3 120, 3 751, 3 757 and 3 765 (`zig build gbtrace -- kills`,
    // `arachnus_health` 6 to 0). The first lands at tick 300, not the
    // recording's +2 005 from the opening shot: those frames are the player's
    // rolls, which `arachnus roll` grades, and a case twice as long would
    // outrun the cart's record. The sixth turns it into the Spring Ball. The
    // behaviour fault takes a bomb for any other weapon.
    .{ .name = "arachnus kill", .ai = 0x5109, .bank = 0xD, .cell = 0xC0, .frames = 1000, .freeze = true, .behaviour = .{ .label = "EnAiArachnus_bombTest", .bytes = &.{0x80} }, .hits = &.{
        .{ .tick = 10, .weapon = 0x01, .dir = 0x02 },
        .{ .tick = 300, .weapon = 0x09, .dir = 0xFF },
        .{ .tick = 310, .weapon = 0x09, .dir = 0xFF },
        .{ .tick = 318, .weapon = 0x09, .dir = 0xFF },
        .{ .tick = 949, .weapon = 0x09, .dir = 0xFF },
        .{ .tick = 955, .weapon = 0x09, .dir = 0xFF },
        .{ .tick = 963, .weapon = 0x09, .dir = 0xFF },
    } },
    // 1.0 Step 14: the Gamma, in `$E:$85` -- Metroid 41 on the roster, and
    // the recording's kill 16 (part 10). Not the census's `$A:$36`, where
    // this rung's Gamma never moves: every probe it makes there hits, on both
    // machines, whichever side Samus stands. Here it lunges along seven angles
    // in 600 frames and bolts at the end of each.
    //
    // **Samus is frozen** (`freeze`): the molt freezes and thaws her, and she
    // thaws a frame apart on the two machines -- the enemy pass's parity -- so
    // her camera, and every slot's screen position with it, runs a frame apart
    // from then on. What that gives up is the range test before the molt,
    // which a raised cutscene flag skips. The molt ends and the fight starts
    // at tick 126. The behaviour fault fires the bolt five passes early, on
    // the pause's first.
    .{ .name = "gamma", .ai = 0x6F60, .bank = 0xE, .cell = 0x85, .frames = 600, .freeze = true, .behaviour = .{ .label = "EnAiGamma_fireTest", .bytes = &.{0x80} } },
    // And shot: a beam's dink, missiles from four directions that stun, blink
    // and push it -- the push probed, the other axis the coin's -- and a screw
    // attack. The behaviour fault puts every leftward push back, as if its
    // probe had hit.
    .{ .name = "gamma shot", .ai = 0x6F60, .bank = 0xE, .cell = 0x85, .frames = 700, .freeze = true, .behaviour = .{ .label = "EnAiGamma_leftProbe", .bytes = &.{0x80} }, .hits = &.{
        .{ .tick = 140, .weapon = 0x00, .dir = 0x01 },
        .{ .tick = 180, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 250, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 330, .weapon = 0x08, .dir = 0x08 },
        .{ .tick = 400, .weapon = 0x10, .dir = 0x01 },
        .{ .tick = 480, .weapon = 0x08, .dir = 0x04 },
    } },
    // The kill, at the recording's own spacing -- but kill 26's, `$A:$36`,
    // part 12 (`zig build gbtrace -- kills`), and not kill 16's in this room,
    // whose fight leaves the screen four times and restarts each time it comes
    // back. Kill 26's fight starts at 24 113 and ten missiles from the right
    // land at +72, +130, +160, +220, +280, +306, +334, +392, +462 and +566, the
    // last the kill; two more at +202 and +434 land while its bolt is out and
    // do nothing, which is `.checkIfHurt`'s `$05`. This case's fight starts
    // on tick 126. The behaviour fault lets a shot at the bolt's time hurt.
    .{ .name = "gamma kill", .ai = 0x6F60, .bank = 0xE, .cell = 0x85, .frames = 1100, .freeze = true, .behaviour = .{ .label = "EnAiGamma_boltTest", .bytes = &.{0x80} }, .hits = &.{
        .{ .tick = 126 + 72, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 130, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 160, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 202, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 220, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 280, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 306, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 334, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 392, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 434, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 462, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 126 + 566, .weapon = 0x08, .dir = 0x02 },
    } },
    // 1.0 Step 15: the Zeta, in the census's `$A:$F8` -- Metroid 4 on the
    // roster, and the recording's kill 30 (part 13). Samus is frozen, as for
    // the Gamma: the intro freezes and thaws her.
    .{ .name = "zeta", .ai = 0x7276, .bank = 0xA, .cell = 0xF8, .frames = 900, .freeze = true, .behaviour = .{ .label = "EnAiZeta_waitTest", .bytes = &.{0x80} } },
    // And shot, in each of its states: a beam's dink, missiles from the right,
    // the left and above that stun it, cycle its hurt sprites and push it --
    // with no probe -- and one from below that only dinks (`BIT 2`), a
    // screw attack, and a missile while it is stunned. The fight starts on
    // tick 242. The behaviour fault pushes a missile going down to the left.
    .{ .name = "zeta shot", .ai = 0x7276, .bank = 0xA, .cell = 0xF8, .frames = 700, .freeze = true, .behaviour = .{ .label = "EnAiZeta_downTest", .bytes = &.{0x80} }, .hits = &.{
        .{ .tick = 250, .weapon = 0x00, .dir = 0x01 },
        .{ .tick = 262, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 266, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 300, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 340, .weapon = 0x08, .dir = 0x08 },
        .{ .tick = 380, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 420, .weapon = 0x10, .dir = 0x01 },
        .{ .tick = 520, .weapon = 0x08, .dir = 0x08 },
        .{ .tick = 580, .weapon = 0x08, .dir = 0x01 },
    } },
    // The kill, at the recording's own spacing: **kill 30's** (`$A:$F8`, part
    // 13, `zig build gbtrace -- kills`). Its fight starts at 24 763 and twenty
    // missiles hurt it, the first ten from the right but one from above, the
    // rest from the left; two from below at +1 074 and +1 086 only dink. This
    // case's fight starts on tick 242. **One gap is 500 shorter than the
    // recording's**: nothing lands from +418 to +1 074, and at full length the
    // case outruns the case cart's save RAM (`TooManyRecords` at 2 000 ticks),
    // so every hit from +1 074 on is 500 earlier and keeps its spacing. It runs
    // past the post-death timer's $90: cut mid-climb, the cart's history is one
    // step short, which is pass parity. The behaviour fault lets a missile from
    // below hurt.
    .{ .name = "zeta kill", .ai = 0x7276, .bank = 0xA, .cell = 0xF8, .frames = 1560, .freeze = true, .behaviour = .{ .label = "EnAiZeta_upTest", .bytes = &.{ 0xEA, 0xEA } }, .hits = &.{
        .{ .tick = 242 + 26, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 54, .weapon = 0x08, .dir = 0x08 },
        .{ .tick = 242 + 86, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 112, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 130, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 148, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 166, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 188, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 206, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 232, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 242 + 418, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1074 - 500, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 242 + 1086 - 500, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 242 + 1274 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1296 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1322 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1356 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1388 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1410 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1440 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1468 - 500, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 242 + 1498 - 500, .weapon = 0x08, .dir = 0x02 },
    } },
    // 1.0 Step 16: the Omega, in the census's `$B:$76` -- Metroid 14 on the
    // roster. Samus is frozen, as for the Gamma and the Zeta.
    .{ .name = "omega", .ai = 0x7631, .bank = 0xB, .cell = 0x76, .frames = 1200, .freeze = true, .behaviour = .{ .label = "EnAiOmega_waitTest", .bytes = &.{0x80} } },
    // And shot, in each of its states: a beam's dink, a missile in front (one
    // health, a stun of three), one in the back (three, and $10), one during
    // the stun, one going down and one going up that only dink (`AND $03`), a
    // screw attack, whose chase takes index 3, and one more in front and one
    // in the back after it: health $28, $27, $24, $23, $20. The fight starts
    // on tick 190. The behaviour fault lets a missile going up or down hurt.
    // Hits in the back of a right-facing Omega are `omega kill`'s.
    .{ .name = "omega shot", .ai = 0x7631, .bank = 0xB, .cell = 0x76, .frames = 700, .freeze = true, .behaviour = .{ .label = "EnAiOmega_vertTest", .bytes = &.{ 0xEA, 0xEA } }, .hits = &.{
        .{ .tick = 200, .weapon = 0x00, .dir = 0x01 },
        .{ .tick = 210, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 230, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 240, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 280, .weapon = 0x08, .dir = 0x08 },
        .{ .tick = 300, .weapon = 0x08, .dir = 0x04 },
        .{ .tick = 340, .weapon = 0x10, .dir = 0x01 },
        .{ .tick = 540, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 600, .weapon = 0x08, .dir = 0x02 },
    } },
    // The kill, at the recording's own spacing: **kill 38's** (`$B:$75`, part
    // 20, `zig build gbtrace -- kills`), an Omega a cell from this one. Its
    // fight starts at 511, and of the eighteen missiles that hurt it the first
    // is in front, the next seven in the back, five in front and five in the
    // back, the last the kill: health $28, $27, $24 .. $12, $11 .. $0D, $0A ..
    // $01. This case's fight starts on tick 190. **Three gaps are shorter than
    // the recording's** -- the fight's start to the first hurt by 250, the
    // first hurt to the second by 400, the thirteenth to the fourteenth by 200
    // -- because at full length the case cart's save RAM runs out before the
    // post-death timer ends, and a cut mid-climb leaves the two machines' timer
    // histories a pass apart. **Each missile's direction is chosen to hit the
    // side the recording's did**, from the way this Omega faces at that tick
    // (a missile going left is in the back of one facing left): Samus stands
    // elsewhere here, so the recording's own directions would hit other
    // sides. The health steps are then the recording's exactly. The behaviour
    // fault takes a missile into a left-facing back for one in front.
    .{ .name = "omega kill", .ai = 0x7631, .bank = 0xB, .cell = 0x76, .frames = 1760, .freeze = true, .behaviour = .{ .label = "EnAiOmega_backTest", .bytes = &.{0x80} }, .hits = &.{
        .{ .tick = 190 + 571 - 250, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1101 - 650, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 1135 - 650, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 1185 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1219 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1269 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1303 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1353 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1453 - 650, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 1499 - 650, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 1547 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1567 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1595 - 650, .weapon = 0x08, .dir = 0x02 },
        .{ .tick = 190 + 1926 - 850, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 1960 - 850, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 1998 - 850, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 2032 - 850, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 190 + 2068 - 850, .weapon = 0x08, .dir = 0x01 },
    } },
    // 1.0 Step 17: the stinger, `$E:$22` #43, the final area's event: the
    // eight larvae onto the shown count, the hive's song, Samus frozen, and on
    // its $8A'th pass its own deletion, its flag dead and her thaw -- tick 274
    // on both machines. **The case ends on that tick.** Measured: the room's
    // own record loads during the Game Boy's settle and freezes her mid-fall
    // (the cutscene flag $01 and pose $0F where the settle stops), so the
    // "stillness" is the freeze and the fall's momentum is not in the cart's
    // boot record; past the thaw the two falls differ, which is the harness's
    // placement, not the AI. Not frozen by the case, so the flag is graded.
    .{ .name = "stinger", .ai = 0x6B83, .bank = 0xE, .cell = 0x22, .frames = 275, .min_passes = 2, .behaviour = .{ .label = "EnAiStinger_larvae", .bytes = &.{ 0x69, 0x00 } } },
    // 1.0 Step 17: the larvae. Samus is not frozen: a larva's whole business
    // is reaching her. In `$D:$10` (Metroid 29) with her $30 left of the
    // centre, it seeks her and latches on at tick 34, and drains her three
    // every eighth frame (`HealthLo`). The drains land a frame apart on the two
    // machines, and the first touch a frame apart, which the enemy pass's
    // parity decides, so the cart is one drain behind from the start; the
    // collapsed history agrees, and **every larva case ends on a tick that is a
    // multiple of eight**, after both machines' drain, or the last step is
    // cut on one of them. Each case ends long before her health does: past it
    // the Game Boy's ticks stop being frames (its logic point is in the play
    // handler, which a death leaves), and the rung cannot grade a death. The
    // behaviour fault leaves the touch unlatched.
    .{ .name = "larva", .ai = 0x7A4F, .bank = 0xD, .cell = 0x10, .samus_dx = -0x30, .frames = 241, .behaviour = .{ .label = "EnAiLarva_latchOn", .bytes = &.{ 0xA9, 0x00 } } },
    // Bombed off her: a bomb at tick 100 makes it fly off, up and left for $18
    // passes; it seeks her again and latches at 182, and a second bomb lands
    // at +62, the recording's spacing between re-latch and bomb (part 21,
    // 21 178 and 21 240). Both are **late hits** (`Hit.late`): her touch of the
    // larva on her writes the same byte earlier in the frame. The behaviour
    // fault keeps it on her.
    .{ .name = "larva bomb", .ai = 0x7A4F, .bank = 0xD, .cell = 0x10, .samus_dx = -0x30, .frames = 249, .behaviour = .{ .label = "EnAiLarva_bombTest", .bytes = &.{0x80} }, .hits = &.{
        .{ .tick = 100, .weapon = 0x09, .dir = 0x00, .late = true },
        .{ .tick = 182 + 62, .weapon = 0x09, .dir = 0x00, .late = true },
    } },
    // The kill, at the recording's own spacing: **kill 40's** (part 21, `$E:$32`,
    // `zig build gbtrace -- kills`). The first ice shot freezes it at 15 629,
    // seven more keep it frozen, and five missiles take its five health from
    // 15 736 to 15 828. Here in `$D:$00` (Metroid 27), where it wedges against
    // the terrain short of Samus, the first ice lands at tick 40. The kill takes
    // both counts down one and arms the quake check. The behaviour fault lets
    // the fifth missile leave it alive.
    // 1.0 Step 21: the baby Metroid, `$F:$A7` #42, the egg the Queen leaves.
    // With Samus $40 right of the cell's centre she is in its range: it blinks
    // and wiggles from tick 0, bursts at 94, rises from 118 and follows her
    // from 142, at rest beside her. The behaviour fault puts her out of range.
    .{ .name = "baby", .ai = 0x7BE5, .bank = 0xF, .cell = 0xA7, .samus_dx = 0x40, .frames = 400, .behaviour = .{ .label = "EnAiBaby_nearTest", .bytes = &.{ 0xC9, 0x00 } } },
    // The block it eats: from tick 150 Samus walks left until the step at the
    // cell's (10,4) stops her, the baby's left probe meets the step's tile $64
    // and eats it at 194 -- four tiles of $FF, graded on the map (`tiles_end`).
    // The behaviour fault eats nothing.
    .{ .name = "baby block", .ai = 0x7BE5, .bank = 0xF, .cell = 0xA7, .samus_dx = 0x40, .frames = 300, .tiles_end = true, .fire = &.{
        .{ .from = 150, .to = 300, .key = .{ .left = true } },
    }, .behaviour = .{ .label = "BabyClearBlock", .bytes = &.{0x60} } },
    .{ .name = "larva kill", .ai = 0x7A4F, .bank = 0xD, .cell = 0x00, .frames = 400, .behaviour = .{ .label = "EnAiLarva_healthTest", .bytes = &.{ 0xEA, 0xEA } }, .hits = &.{
        .{ .tick = 40 + 0, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 8, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 16, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 24, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 34, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 44, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 64, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 76, .weapon = 0x01, .dir = 0x01 },
        .{ .tick = 40 + 107, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 40 + 131, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 40 + 155, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 40 + 177, .weapon = 0x08, .dir = 0x01 },
        .{ .tick = 40 + 199, .weapon = 0x08, .dir = 0x01 },
    } },
};

/// The slot bytes compared, in slot order: status, Y, X, sprite, attr,
/// generalVar, directionFlags, counter, state, spawn flag. Health, stun and the
/// rest are other steps' mechanisms and would make an AI's history depend on
/// them.
pub const sample_fields = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x05, 0x07, 0x08, 0x09, 0x0A, 0x1C };
/// How many slots each record carries, from slot 0. The seeded enemy is slot 0;
/// the rest are what it makes -- a pipe bug's spawner fills slot 1 with the bug
/// -- and a loaded neighbour would land in them too.
pub const sample_slots: usize = 4;

/// **Step 19's rung: the record's lifecycle, not an AI's.** The screen leaves an
/// enemy, goes far enough for the slot to be deleted for good, and comes back,
/// and what is graded is whether the *record* is live again and under which
/// spawn flag -- `DeactivateOffscreen` (02:$452E), `DeleteOffscreen` ($4464),
/// `ReactivateOffscreen` ($44C0) and the walk that reloads it (03:$4014). It is
/// a separate list from `cases` so the `enemy AIs` rung is unmoved by it.
///
/// **Three of them ask the question a transition asks**, with `resets`: the room
/// reset empties every slot and puts the saved half of the spawn flags out to
/// its bank's window and back again, and a Metroid's spawn number is in that
/// saved half -- the ROM's Metroid records are numbers $40 to $56, and the
/// unsaved half below $40 is refilled with $FF on every room load. So a wrong
/// flag for a Metroid is permanent where a wrong flag for a Gullugg is gone at
/// the next door, which is why the entry this rung was built for names Metroids.
///
/// **The two Metroids in the slice and one ordinary enemy**, because the
/// mechanism is the same code for both and the saved half is the difference.
/// Every case is `by_number` and `freeze`; see those fields for what that costs
/// and why the alternative was measured and dropped.
pub const reload_cases = [_]Case{
    // Alpha 1, the hatching one, in the room its record is in. Its intro has
    // frozen Samus anyway, which is how `freeze` came to be measured.
    .{ .name = "alpha reload", .by_number = true, .freeze = true, .ai = 0x6BB2, .bank = 0xF, .cell = 0x10, .frames = 560, .min_passes = 2, .sweep = &.{
        .{ .dx = 8, .ticks = 260 },
        .{ .dx = -8, .ticks = 260 },
    } },
    // Alpha 2, the plain one, in the room the Step 13c cases grade it in.
    .{ .name = "alpha2 reload", .by_number = true, .freeze = true, .ai = 0x6C44, .bank = 0xE, .cell = 0xB2, .frames = 560, .min_passes = 2, .sweep = &.{
        .{ .dx = 8, .ticks = 260 },
        .{ .dx = -8, .ticks = 260 },
    } },
    // And an ordinary enemy, whose number is in the *unsaved* half: the same
    // code, the half a room load refills, and the control for the two above.
    .{ .name = "crawler away", .by_number = true, .freeze = true, .ai = 0x57DE, .bank = 0xF, .cell = 0x6A, .frames = 560, .min_passes = 2, .sweep = &.{
        .{ .dx = 8, .ticks = 260 },
        .{ .dx = -8, .ticks = 260 },
    } },
    // The same three with the room reset a transition asks for, fired while the
    // record is live and off the screen. See `Case.resets`.
    .{ .name = "alpha reset", .by_number = true, .freeze = true, .ai = 0x6BB2, .bank = 0xF, .cell = 0x10, .frames = 460, .min_passes = 2, .resets = &.{ 20, 140 }, .sweep = &.{
        .{ .dx = 8, .ticks = 120 },
        .{ .dx = -8, .ticks = 120 },
    } },
    .{ .name = "alpha2 reset", .by_number = true, .freeze = true, .ai = 0x6C44, .bank = 0xE, .cell = 0xB2, .frames = 460, .min_passes = 2, .resets = &.{ 20, 140 }, .sweep = &.{
        .{ .dx = 8, .ticks = 120 },
        .{ .dx = -8, .ticks = 120 },
    } },
    .{ .name = "crawler reset", .by_number = true, .freeze = true, .ai = 0x57DE, .bank = 0xF, .cell = 0x6A, .frames = 460, .min_passes = 2, .resets = &.{ 20, 140 }, .sweep = &.{
        .{ .dx = 8, .ticks = 120 },
        .{ .dx = -8, .ticks = 120 },
    } },
};

/// A Metroid global: its Game Boy address and the engine symbol for the port's.
pub const Global = struct { gb: u16, sym: []const u8 };
/// The globals compared beside the slots, from M2RoS `SRC/ram/wram.asm`.
///
/// **Collapsed, so the post-death timer is graded on its values and not on
/// which frames it steps on.** It steps when the frame counter is even
/// (02:$4041), and the enemy pass that sets it going lands on the other parity
/// on the two machines: measured on `alpha kill` with the counter compared too,
/// the counters agree on every tick and the killing pass runs at $D4 on the Game
/// Boy and $D5 on the cart -- the pass parity this file already calls a
/// property of the boot -- so the cart's first step comes a frame sooner.
/// `snes boot` grades the even-frame rule itself.
pub const globals = [_]Global{
    .{ .gb = 0xC41B, .sym = "VarMetPostDeath" }, // metroid_postDeathTimer
    .{ .gb = 0xC41C, .sym = "VarMetState" }, // metroid_state
    .{ .gb = 0xC463, .sym = "VarCutscene" }, // cutsceneActive
    .{ .gb = 0xC464, .sym = "VarAlphaStun" }, // alpha_stunCounter
    .{ .gb = 0xC465, .sym = "VarMetFight" }, // metroid_fightActive
    .{ .gb = 0xD089, .sym = "VarMetReal" }, // metroidCountReal
    .{ .gb = 0xD09A, .sym = "VarMetDisp" }, // metroidCountDisplayed
    // Step 14: the countdown a kill arms and the quake it starts. Only the
    // arming and the first tick fit inside a kill case: the quake's 255 steps
    // would outrun the cart's save file of change records, so its rule is
    // `snes boot` phase 23's and its timing the recording's (`docs/slice.md`).
    .{ .gb = 0xD091, .sym = "VarQuakeNext" }, // nextEarthquakeTimer
    .{ .gb = 0xD083, .sym = "VarQuakeTimer" }, // earthquakeTimer
    // 1.0 Step 8b: slot 0's stun, ice counter and health, the bytes a beam's
    // hit writes. As globals and not `sample_fields`, because every field there
    // is paid four times a record and the save file overflowed; a hit only
    // ever lands on slot 0 here. Collapsed like the rest, so the ice counter is
    // graded on the values it climbs through and the status byte's blink and
    // the thaw's return to the AI grade when.
    .{ .gb = 0xC606, .sym = "VarSlot0Stun" }, // enemy slot 0 +$06 stunCounter
    .{ .gb = 0xC60B, .sym = "VarSlot0Ice" }, // +$0B iceCounter
    .{ .gb = 0xC60C, .sym = "VarSlot0Health" }, // +$0C health
    // 1.0 Step 12: the blob thrower's state, which is global and not its
    // slot's (`$C380`-`$C386`), and the three bytes of its WRAM part list and
    // hitbox it rewrites that the slot never shows: the mouth's character, the
    // lip's Y and the hitbox's top. Zero in every other case.
    .{ .gb = 0xC380, .sym = "VarBlobAction" }, // blobThrower_actionTimer
    .{ .gb = 0xC381, .sym = "VarBlobWait" }, // blobThrower_waitTimer
    .{ .gb = 0xC382, .sym = "VarBlobState" }, // blobThrower_state
    .{ .gb = 0xC386, .sym = "VarBlobFacing" }, // blobThrower_facingDirection
    .{ .gb = 0xC302, .sym = "VarBlobMouth" }, // enSprite_blobThrower part 0's character
    .{ .gb = 0xC334, .sym = "VarBlobLipY" }, // part 13's Y
    .{ .gb = 0xC360, .sym = "VarBlobBoxTop" }, // hitboxC360's top
    // 1.0 Step 13: Arachnus's, which is global too ($C390-$C394). Its health
    // is here and not in its slot, which holds $FF: the bombs' countdown.
    .{ .gb = 0xC390, .sym = "VarArachJumpN" }, // arachnus_jumpCounter
    .{ .gb = 0xC391, .sym = "VarArachTimer" }, // arachnus_actionTimer
    .{ .gb = 0xC393, .sym = "VarArachStatus" }, // arachnus_jumpStatus
    .{ .gb = 0xC394, .sym = "VarArachHealth" }, // arachnus_health
    // 1.0 Step 14: the Gamma's stun counter, its own and not the Alpha's.
    .{ .gb = 0xC46A, .sym = "VarGammaStun" }, // gamma_stunCounter
    // 1.0 Step 15: the Zeta's.
    .{ .gb = 0xC46C, .sym = "VarZetaStun" }, // zeta_stunCounter
    // 1.0 Step 16: the Omega's stun, and the two that pick its chases.
    .{ .gb = 0xC462, .sym = "VarOmegaStun" }, // omega_stunCounter
    .{ .gb = 0xC46F, .sym = "VarOmegaWait" }, // omega_waitCounter
    .{ .gb = 0xC478, .sym = "VarOmegaChaseIx" }, // omega_chaseTimerIndex
    .{ .gb = 0xC473, .sym = "VarLarvaHurtN" }, // larva_hurtAnimCounter
    .{ .gb = 0xC474, .sym = "VarLarvaBomb" }, // larva_bombState
    .{ .gb = 0xC475, .sym = "VarLarvaLatch" }, // larva_latchState
    .{ .gb = 0xD051, .sym = "VarHealthLo" }, // samusCurHealthLow
    // 1.0 Step 21: the baby's. The tile is what the mid probes leave, and
    // which of them read last is what decides a block. `baby_tempXpos`
    // ($C43B) is not here: it holds the X the same pass puts back, so its
    // history is the slot's, and a record more is what the longest cases'
    // save files do not have.
    .{ .gb = 0xC417, .sym = "VarBabyTile" }, // metroid_babyTouchingTile
};
const slots_bytes: usize = sample_fields.len * sample_slots;
pub const Sample = [slots_bytes + globals.len]u8;

const slot_bytes: usize = 0x20;
const slot_count: usize = 16;

// The Game Boy's addresses, from M2RoS `SRC/ram/wram.asm` and `hram.asm`.
const gb_slots: u16 = 0xC600;
const gb_spawn_flags: u16 = 0xC500;
/// `justStartedTransition`. See `Case.resets`.
const gb_just_started: u16 = 0xD09E;
/// `cutsceneFlag`, which holds Samus still. See `Case.freeze`.
const gb_cutscene: u16 = 0xC463;
const gb_num_total: u16 = 0xC425;
const gb_num_active: u16 = 0xC426;
const gb_num_offscreen: u16 = 0xC427;
const gb_same_frame: u16 = 0xC438;
const gb_left_to_process: u16 = 0xC439;
const gb_larva_bomb: u16 = 0xC474; // larva_bombState
const gb_larva_latch: u16 = 0xC475; // larva_latchState
const gb_frame_counter: u16 = 0xFFFE;
pub const gb_scroll_y: u16 = 0xC205;
pub const gb_scroll_x: u16 = 0xC206;
const gb_pose: u16 = 0xD020;
const gb_counter: u16 = 0xFF97;
/// `collision_weaponType`, `collision_pEnemy` and `collision_weaponDir`, which
/// `enemy_getDamagedOrGiveDrop` compares against the slot's WRAM address.
const gb_coll_weapon: u16 = 0xD05D;
const gb_coll_enemy: u16 = 0xD05E;
const gb_coll_dir: u16 = 0xD060;
/// `alpha_stunCounter`: a hurt sets it to `alpha_stun_n` on the pass it lands.
/// `gamma_stunCounter` is the Gamma's (1.0 Step 14), set to the same eight;
/// a hurt is either counter arriving at it, and only one ever moves in a case.
const gb_alpha_stun: u16 = 0xC464;
const gb_gamma_stun: u16 = 0xC46A;
/// `zeta_stunCounter`, the Zeta's (1.0 Step 15), set to the same eight.
const gb_zeta_stun: u16 = 0xC46C;
const gb_stuns = [_]u16{ gb_alpha_stun, gb_gamma_stun, gb_zeta_stun };
const alpha_stun_n: u8 = 0x08;

/// `OAM_Y_OFS` and `OAM_X_OFS`: the biases `loadOneEnemy` adds before it
/// subtracts the scroll.
const oam_y_ofs: u8 = 16;
const oam_x_ofs: u8 = 8;

/// A loaded slot's spawn flag: `$FF` "never seen" becomes `$01`, 03:$4265.
const flag_active_new: u8 = 0x01;
const wpn_missile: u8 = 0x08;

/// The AI a sprite id's header names: the trailing word of its 11-byte record.
pub const aiFor = roster.aiFor;

/// The first spawn record in a cell whose sprite's header names `ai`.
pub fn recordFor(allocator: std.mem.Allocator, rom: []const u8, c: Case) !entity.Spawn {
    const data_e = offsets.find("enemy_data").?;
    const lists = try entity.parseSpawnLists(allocator, rom[data_e.romOffset()..data_e.romEnd()], data_e.gb_addr);
    defer entity.freeSpawnLists(allocator, lists);
    const index = (@as(usize, c.bank) - 9) * entity.screens_per_bank + c.cell;
    for (lists[index].spawns) |s| {
        if (aiFor(rom, s.sprite) == c.ai) return s;
    }
    return Error.NoRecordWithAi;
}

/// `loadOneEnemy`'s 32 bytes for one record under one scroll, exactly as
/// 03:$422F lays them out: status, Y, X, sprite, the header's nine, four
/// cleared, the initial health, the flag at +$1C, the number at +$1D, the AI
/// word at +$1E. Everything the routine does not write is `$FF`, which is what
/// an emptied slot holds on both machines.
pub fn seedSlot(rom: []const u8, rec: entity.Spawn, scroll_y: u8, scroll_x: u8) [slot_bytes]u8 {
    var s: [slot_bytes]u8 = @splat(0xFF);
    s[0x00] = 0x00;
    s[0x01] = rec.y +% oam_y_ofs -% scroll_y;
    s[0x02] = rec.x +% oam_x_ofs -% scroll_x;
    s[0x03] = rec.sprite;
    const hp = offsets.find("enemy_header_pointers").?;
    const hd = offsets.find("enemy_headers").?;
    const ptrs = rom[hp.romOffset()..hp.romEnd()];
    const at = @as(u16, ptrs[@as(usize, rec.sprite) * 2]) | (@as(u16, ptrs[@as(usize, rec.sprite) * 2 + 1]) << 8);
    const h = rom[hd.romOffset() + (at - hd.gb_addr) ..][0..entity.header_bytes];
    @memcpy(s[0x04..0x0D], h[0..9]);
    @memset(s[0x0D..0x11], 0);
    s[0x11] = h[8];
    s[0x1C] = flag_active_new;
    s[0x1D] = rec.number;
    s[0x1E] = h[9];
    s[0x1F] = h[10];
    return s;
}

/// Where the Game Boy put everything, and what the AI then did.
pub const GbRun = struct {
    settled: room.Placement,
    camera_x: u16,
    camera_y: u16,
    counter: u8,
    /// What she was carrying when the room settled: the new game's, since
    /// `room.bootIntoPlay` starts one, but read rather than assumed.
    loadout: snes_screen.Loadout.Measured,
    scroll_y: u8,
    scroll_x: u8,
    seed: [slot_bytes]u8,
    /// The background map and the hardware scroll at the seed, so the cart's
    /// terrain can be checked before its AI is blamed for walking through it.
    tiles: [1024]u8,
    scx: u8,
    scy: u8,
    /// The map and the scroll after the last tick: `Case.tiles_end`.
    tiles_end: [1024]u8 = undefined,
    scx_end: u8 = 0,
    scy_end: u8 = 0,
    samples: []Sample,
    /// The camera's pixel bytes per tick, Y then X: an enemy's slot position is
    /// camera space, so a camera that moves on one machine and not the other
    /// moves the enemy with it.
    camera: [][2]u8,
    /// What each hurt's coin came up, in order. See `Coin`.
    coins: [max_coins]Coin = undefined,
    coin_n: usize = 0,
    /// What each divider read took, in order, per site. See `Case.dividers`.
    divs: [max_div_sites][max_divs]u8 = undefined,
    div_n: [max_div_sites]usize = .{0} ** max_div_sites,
    /// The sweep's camera and Samus positions per tick, absolute, computed off
    /// where the Game Boy settled -- so the cart is driven to the same numbers
    /// rather than to the same deltas from its own start. Empty when the case
    /// has no sweep. See `Case.sweep`.
    sweep_cam: []u16 = &.{},
    sweep_samus: []u16 = &.{},

    pub fn deinit(self: *GbRun, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        allocator.free(self.camera);
        allocator.free(self.sweep_cam);
        allocator.free(self.sweep_samus);
    }
};

/// The camera's X on each tick of a sweep, and Samus's, from where the room
/// settled. Her distance from the camera is held fixed: the sweep is a scroll,
/// and a scroll moves both.
///
/// **Each position is held for two ticks, and that is what makes a sweep
/// gradable at all.** The enemy pass acts on every other frame and which parity
/// it lands on is a property of each machine's boot, not of the mechanism -- the
/// file comment says so and `passes` collapses histories for it. A camera that
/// moved every tick would turn that one-frame offset into a *position*
/// difference: the load writes `record + OAM offset - scroll`, so a pass one
/// frame late loads the same record one step along. Measured, before this was
/// understood: `crawler away` reloaded its record at x $F5 on the Game Boy and
/// $F1 on the cart, one four-pixel step apart, and nothing else about the two
/// runs disagreed. Held for two ticks, both parities read the same sequence of
/// camera values and the offset is invisible again.
fn sweepPath(allocator: std.mem.Allocator, c: Case, cam0: u16, samus0: u16) !struct { cam: []u16, samus: []u16 } {
    const cam = try allocator.alloc(u16, c.frames);
    errdefer allocator.free(cam);
    const samus = try allocator.alloc(u16, c.frames);
    errdefer allocator.free(samus);
    const gap = samus0 -% cam0;
    var x = cam0;
    var tick: usize = 0;
    for (c.sweep) |leg| {
        for (0..leg.ticks) |_| {
            if (tick == c.frames) break;
            if (tick % 2 == 0) x = @bitCast(@as(i16, @bitCast(x)) +% leg.dx);
            cam[tick] = x;
            samus[tick] = x +% gap;
            tick += 1;
        }
    }
    // A sweep shorter than the case holds the last position, so the ticks after
    // it are the walk and the pass with a still camera rather than no camera.
    while (tick < c.frames) : (tick += 1) {
        cam[tick] = x;
        samus[tick] = x +% gap;
    }
    return .{ .cam = cam, .samus = samus };
}

/// A slot seed for a caller with its own schedule: the loadout segment's
/// enemy (1.0 Step 8c, `oracle.Enemy`), which places it and hands the same
/// bytes to both machines.
pub const Seed = struct { bytes: [slot_bytes]u8, number: u8 };

/// The seed of the first record in `bank`:`cell` whose AI is `ai`, at the
/// record's own position under a zero scroll; the caller places it.
pub fn seedFor(allocator: std.mem.Allocator, rom: []const u8, bank: u8, cell: u8, ai: u16) !Seed {
    const rec = try recordFor(allocator, rom, .{ .name = "", .ai = ai, .bank = bank, .cell = cell });
    return .{ .bytes = seedSlot(rom, rec, 0, 0), .number = rec.number };
}

/// What `runGb` writes at its seed, on the Game Boy: every slot emptied but
/// the seeded one, its spawn flag, the counts, and the pass's own counters, so
/// the pass starts from the top on both machines. The cart's half is
/// `writeSeedLua`.
pub fn seedGb(m: *harness.Machine, sd: Seed) void {
    writeSlots(m, sd.bytes);
    m.write(gb_spawn_flags + sd.number, flag_active_new);
    m.write(gb_num_total, 1);
    m.write(gb_num_active, 1);
    m.write(gb_num_offscreen, 0);
    m.write(gb_frame_counter, 0);
    m.write(gb_same_frame, 0);
    m.write(gb_left_to_process, 0);
}

/// The cart's half of `seedGb`, as a Lua function `seed()` over the table
/// `SEED` (32 bytes) and `SEEDNUMBER`. Written into a script that has `wram`.
pub fn writeSeedLua(w: *std.Io.Writer, sd: Seed) !void {
    try w.print("local SEEDNUMBER = {d}\nlocal SEED = {{", .{sd.number});
    for (sd.bytes) |b| try w.print("{d},", .{b});
    try w.print(
        \\}}
        \\local SEEDSLOTS, SEEDFLAGS = 0x{X:0>4}, 0x{X:0>4}
        \\local SEEDTOTAL, SEEDACTIVE, SEEDOFFSCR = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local SEEDENFRAME, SEEDENSAME, SEEDENLEFT = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local function seed()
        \\  for k = 0, 16 * 32 - 1 do emu.write(SEEDSLOTS + k, 0xFF, wram) end
        \\  for k = 1, 32 do emu.write(SEEDSLOTS + k - 1, SEED[k], wram) end
        \\  emu.write(SEEDFLAGS + SEEDNUMBER, {d}, wram)
        \\  emu.write(SEEDTOTAL, 1, wram)
        \\  emu.write(SEEDACTIVE, 1, wram)
        \\  emu.write(SEEDOFFSCR, 0, wram)
        \\  emu.write(SEEDENFRAME, 0, wram)
        \\  emu.write(SEEDENSAME, 0, wram)
        \\  emu.write(SEEDENLEFT, 0, wram)
        \\end
        \\
    , .{
        try sym("VarSlots") & 0xFFFF,    try sym("VarSpawnFlags") & 0xFFFF,
        try sym("VarEnTotal") & 0xFFFF,  try sym("VarEnActive") & 0xFFFF,
        try sym("VarEnOffscr") & 0xFFFF, try sym("VarEnFrame") & 0xFFFF,
        try sym("VarEnSame") & 0xFFFF,   try sym("VarEnLeftN") & 0xFFFF,
        flag_active_new,
    });
}

/// 00:$0538, the play handler's next call after `collision_samusEnemies`.
const gb_after_contact_pc: u16 = 0x0538;

fn lateHit(hits: []const Hit, tick: usize) ?Hit {
    for (hits) |h| if (h.late and h.tick == tick) return h;
    return null;
}

fn writeSlots(m: *harness.Machine, seed: [slot_bytes]u8) void {
    for (0..slot_count * slot_bytes) |i| m.write(gb_slots + @as(u16, @intCast(i)), 0xFF);
    for (seed, 0..) |b, i| m.write(gb_slots + @as(u16, @intCast(i)), b);
}

pub fn runGb(allocator: std.mem.Allocator, rom: []const u8, c: Case, boot: snes_screen.Boot) !GbRun {
    const rec = try recordFor(allocator, rom, c);

    var m = try room.bootIntoPlay(allocator, rom);
    defer m.deinit();
    // Before the spawn's door script runs: a lava door reads the count.
    if (c.count) |n| m.write(comptime oracle.saveAddr("metroid_count_real"), n);

    var sp = oracle.startFor(boot).spawn();
    sp.pixel_x = @truncate(@as(u16, @bitCast(@as(i16, sp.pixel_x) + c.samus_dx)));
    sp.writes = &.{.{ .addr = gb_pose, .value = oracle.start_pose }};
    _ = try room.spawn(&m, sp);

    // Stillness, the way `oracle.reference` settles a segment.
    var still: usize = 0;
    var prev = room.placement(&m);
    var waited: usize = 0;
    while (waited < oracle.settle_limit and still < oracle.settle_still) : (waited += 1) {
        _ = try m.runFrames(1, oracle.gbKeys(oracle.key.none));
        const now = room.placement(&m);
        still = if (now.eql(prev)) still + 1 else 0;
        prev = now;
    }
    if (still < oracle.settle_still) return Error.NeverSettled;

    try oracle.stepToLogicPoint(&m);
    const settled = room.placement(&m);
    const scroll_y = m.read(gb_scroll_y);
    const scroll_x = m.read(gb_scroll_x);
    const seed = seedSlot(rom, rec, scroll_y, scroll_x);
    var tiles: [1024]u8 = undefined;
    const bg_base: u16 = if (m.read(0xFF40) & 0x08 != 0) 0x9C00 else 0x9800;
    for (&tiles, 0..) |*t, i| t.* = m.read(bg_base + @as(u16, @intCast(i)));
    var out: GbRun = .{
        .settled = settled,
        .camera_x = (@as(u16, m.read(room.camera_screen_x_addr)) << 8) | m.read(room.camera_pixel_x_addr),
        .camera_y = (@as(u16, m.read(room.camera_screen_y_addr)) << 8) | m.read(room.camera_pixel_y_addr),
        .counter = m.read(gb_counter),
        .loadout = oracle.gbLoadout(&m),
        .scroll_y = scroll_y,
        .scroll_x = scroll_x,
        .seed = seed,
        .tiles = tiles,
        .scx = m.read(0xFF43),
        .scy = m.read(0xFF42),
        .samples = try allocator.alloc(Sample, c.frames),
        .camera = try allocator.alloc([2]u8, c.frames),
    };
    errdefer allocator.free(out.samples);
    errdefer allocator.free(out.camera);
    if (c.sweep.len != 0) {
        const path = try sweepPath(
            allocator,
            c,
            out.camera_x,
            (@as(u16, m.read(room.samus_screen_x_addr)) << 8) | m.read(room.samus_pixel_x_addr),
        );
        out.sweep_cam = path.cam;
        out.sweep_samus = path.samus;
    }
    errdefer allocator.free(out.sweep_cam);
    errdefer allocator.free(out.sweep_samus);

    writeSlots(&m, seed);
    m.write(gb_spawn_flags + rec.number, flag_active_new);
    m.write(gb_num_total, 1);
    m.write(gb_num_active, 1);
    m.write(gb_num_offscreen, 0);
    m.write(gb_frame_counter, 0);
    m.write(gb_same_frame, 0);
    m.write(gb_left_to_process, 0);
    // 1.0 Step 17: the two larva bytes a room's entry clears (02:$4013). The
    // settle runs the room, and a larva of `$D:$00`'s touched Samus in it --
    // `larva_bombState` $01 at the seed, measured -- where the cart boots from
    // a clean slate. The reference side, as the slots are.
    m.write(gb_larva_bomb, 0);
    m.write(gb_larva_latch, 0);

    if (c.dividers.len > max_div_sites) return Error.TooManyRecords;
    var dw: DivWatch = .{ .m = &m, .pcs = c.dividers };
    if (c.dividers.len != 0) m.sys.bus.read_watch = .{ .ctx = &dw, .read = DivWatch.read };
    defer m.sys.bus.read_watch = null;

    var prev_stun: [gb_stuns.len]u8 = undefined;
    for (gb_stuns, &prev_stun) |a, *p| p.* = m.read(a);
    for (out.samples, out.camera, 0..) |*s, *cam, tick| {
        for (c.hits) |h| {
            if (h.tick != tick or h.late) continue;
            m.write(gb_coll_weapon, h.weapon);
            m.write(gb_coll_enemy, @truncate(gb_slots));
            m.write(gb_coll_enemy + 1, @truncate(gb_slots >> 8));
            m.write(gb_coll_dir, h.dir);
        }
        if (c.freeze) m.write(gb_cutscene, 0x01);
        for (c.resets) |at| {
            if (at == tick) {
                // **Both bytes, because the port has one.** The original keys
                // three things on two: `$C44B` (`loadSpawnFlagsRequest`, raised
                // by the door interpreter's end at 00:$26D7 with the
                // transition's progress byte) gates the flags-and-slots reset
                // at 02:$4069, and `$D09E` (`justStartedTransition`, raised
                // $FF by the door trigger at 00:$0C63) gates the fight-ending
                // arm and the collision clears at 02:$4009. A crossing raises
                // both, and `!SpawnReload` is the port's single byte for the
                // pair -- so a fixture that raised one of them would grade the
                // merge as a defect it is not.
                m.write(room.spawn_reload_addr, 0x02);
                m.write(gb_just_started, 0xFF);
            }
        }
        if (c.sweep.len != 0) {
            m.write(room.camera_pixel_x_addr, @truncate(out.sweep_cam[tick]));
            m.write(room.camera_screen_x_addr, @truncate(out.sweep_cam[tick] >> 8));
            m.write(room.samus_pixel_x_addr, @truncate(out.sweep_samus[tick]));
            m.write(room.samus_screen_x_addr, @truncate(out.sweep_samus[tick] >> 8));
        }
        const pad = pressed(c.fire, tick);
        if (lateHit(c.hits, tick)) |h| {
            // `oracle.stepOneTick`, with the hit written where the tick passes
            // Samus's contact test. See `Hit.late`.
            const b = oracle.gbKeys(pad);
            m.sys.bus.setKeys(b.dpad, b.buttons);
            _ = try m.sys.step();
            var n: u64 = 0;
            while (m.sys.cpu.pc != gb_after_contact_pc) : (n += 1) {
                if (n >= harness.Machine.instructions_per_frame_cap) return Error.LateHitMissed;
                _ = try m.sys.step();
            }
            m.write(gb_coll_weapon, h.weapon);
            m.write(gb_coll_enemy, @truncate(gb_slots));
            m.write(gb_coll_enemy + 1, @truncate(gb_slots >> 8));
            m.write(gb_coll_dir, h.dir);
            try oracle.stepToLogicPoint(&m);
        } else try oracle.stepOneTick(&m, oracle.gbKeys(pad));
        var hurt = false;
        for (gb_stuns, &prev_stun) |a, *p| {
            const st = m.read(a);
            if (st == alpha_stun_n and p.* != alpha_stun_n) hurt = true;
            p.* = st;
        }
        if (hurt and out.coin_n < max_coins) {
            // The mask is the latest missile's at or before this tick: not
            // the coin_n-th missile, since 1.0 Step 15, because a Zeta's
            // missile from below dinks and takes no coin, and its kill's
            // missiles come from more than one side.
            var dir: ?u8 = null;
            for (c.hits) |h| {
                if (h.weapon == wpn_missile and h.tick <= tick) dir = h.dir;
            }
            if (dir) |d| {
                const mask = coinMask(d);
                out.coins[out.coin_n] = .{ .mask = mask, .value = m.read(gb_slots + 0x08) & mask };
                out.coin_n += 1;
            }
        }
        if (c.by_number) {
            @memset(s[0..slots_bytes], 0xFF);
            for (0..slot_count) |slot| {
                const base = gb_slots + @as(u16, @intCast(slot * slot_bytes));
                if (m.read(base + 0x00) == 0xFF) continue;
                if (m.read(base + 0x1D) != rec.number) continue;
                for (sample_fields, 0..) |f, i| s[i] = m.read(base + f);
                break;
            }
        } else for (0..sample_slots) |slot| {
            for (sample_fields, 0..) |f, i| s[slot * sample_fields.len + i] = m.read(gb_slots + @as(u16, @intCast(slot * slot_bytes)) + f);
        }
        for (globals, 0..) |g, i| s[slots_bytes + i] = m.read(g.gb);
        cam.* = .{ m.read(room.camera_pixel_y_addr), m.read(room.camera_pixel_x_addr) };
    }
    const bg_end: u16 = if (m.read(0xFF40) & 0x08 != 0) 0x9C00 else 0x9800;
    for (&out.tiles_end, 0..) |*t, i| t.* = m.read(bg_end + @as(u16, @intCast(i)));
    out.scx_end = m.read(0xFF43);
    out.scy_end = m.read(0xFF42);
    for (0..c.dividers.len) |i| {
        @memcpy(out.divs[i][0..dw.n[i]], dw.vals[i][0..dw.n[i]]);
        out.div_n[i] = dw.n[i];
    }
    return out;
}

/// The boot record for a case: `bootFor`'s cell, with Samus, the camera, the
/// pose and the counter's phase taken from where the Game Boy settled -- the
/// same overrides `oracle.grade` makes for the segment.
pub fn cartBoot(boot: snes_screen.Boot, gb: GbRun) snes_screen.Boot {
    var b = boot;
    b.cell = (gb.settled.screen_row << 4) | (gb.settled.screen_col & 0x0F);
    b.samus_x = gb.settled.worldX();
    b.samus_y = gb.settled.worldY();
    b.pose = oracle.start_pose;
    b.cam_x = gb.camera_x;
    b.cam_y = gb.camera_y;
    // Lead 1 since 1.0 Step 21, measured: `baby block` is the first case in
    // which Samus walks, and the walk's alternation (`WalkSpeed`, bit 0 of the
    // counter) ran on the other parity at lead 0 -- the camera a pixel apart
    // on every other frame of it, and the baby with it. Every other case
    // agrees either way.
    b.frame_count = oracle.frameCountSeed(gb.counter, 1);
    b.loadout = gb.loadout.over(b.loadout);
    return b;
}

pub const out_dir = "build-out";
pub const stem = "enemies";

/// Per recorded tick: the sample, `!EnUnhandledAi`'s two bytes, and the
/// camera's pixel bytes, Y then X.
pub const cart_record_bytes: usize = @sizeOf(Sample) + 4;
/// What the cart writes: the tick a record landed on, then the record. Only a
/// record that differs from the one before is written.
pub const cart_entry_bytes: usize = 2 + cart_record_bytes;
/// The save file: a two-byte entry count (`$FFFF` if they did not fit), the
/// tilemap at the seed, then the entries -- and for a `Case.tiles_end` case the
/// tilemap after the last tick in the file's last 1024 bytes, which the
/// entries then stop short of.
const cart_tiles_at: usize = 2;
const cart_entries_at: usize = cart_tiles_at + 1024;
const cart_tiles_end_at: usize = cart_sram_bytes - 1024;
pub const max_cart_entries: usize = (cart_sram_bytes - cart_entries_at) / cart_entry_bytes;
/// `max_cart_entries` for a case that keeps the map at its end too.
pub fn maxCartEntries(tiles_end: bool) usize {
    return if (tiles_end) (cart_tiles_end_at - cart_entries_at) / cart_entry_bytes else max_cart_entries;
}
/// The case cart's save RAM: twice the trace's, since 1.0 Step 8b's three
/// globals made `hatchingAlpha`'s 700 frames one save file too many. See
/// `snes_trace.stampSramOf`.
pub const cart_sram_bytes: usize = 64 * 1024;
const cart_sram_size_byte: u8 = 6;

fn sym(name: []const u8) Error!u32 {
    return inject.symbol(name) orelse Error.MissingSymbol;
}

/// The cart's script: seed at the first commit, record at every commit after.
pub fn writeLua(
    w: *std.Io.Writer,
    seed: [slot_bytes]u8,
    number: u8,
    frames: u16,
    hits: []const Hit,
    coins: []const Coin,
    sweep_cam: []const u16,
    sweep_samus: []const u16,
    resets: []const u16,
    fire: []const Span,
    by_number: bool,
    freeze: bool,
    tiles_end: bool,
    divs: DivHand,
) !void {
    const commit = try sym(oracle.commit_symbol);
    try w.print(
        \\-- Generated by src/enemy_oracle.zig. Do not edit.
        \\local wram = emu.memType.snesWorkRam
        \\local sram = emu.memType.snesSaveRam
        \\local COMMIT = 0x{X:0>6}
        \\local FRAMES = {d}
        \\local SLOTS, SPAWNFLAGS = 0x{X:0>4}, 0x{X:0>4}
        \\local TOTAL, ACTIVE, OFFSCR = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local ENFRAME, ENSAME, ENLEFT = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local UNHANDLED = 0x{X:0>4}
        \\local TILEMAP = 0x{X:0>4}
        \\local CAMY, CAMX = 0x{X:0>4}, 0x{X:0>4}
        \\local NUMBER = {d}
        \\local NSLOTS = {d}
        \\local COLLW, COLLE, COLLD = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}
        \\local STUN, STUN2, STUN3, STUN_N = 0x{X:0>4}, 0x{X:0>4}, 0x{X:0>4}, {d}
        \\local SAMUSX = 0x{X:0>4}
        \\local RELOAD = 0x{X:0>4}
        \\local BYNUMBER = {s}
        \\local CUTSCENE, FREEZE = 0x{X:0>4}, {s}
        \\local TILESEND = {s}
        \\local MAXN, RB = {d}, {d}
        \\local FIELDS = {{
    , .{
        commit,                                    frames,
        try sym("VarSlots") & 0xFFFF,              try sym("VarSpawnFlags") & 0xFFFF,
        try sym("VarEnTotal") & 0xFFFF,            try sym("VarEnActive") & 0xFFFF,
        try sym("VarEnOffscr") & 0xFFFF,           try sym("VarEnFrame") & 0xFFFF,
        try sym("VarEnSame") & 0xFFFF,             try sym("VarEnLeftN") & 0xFFFF,
        try sym("VarEnUnhandledAi") & 0xFFFF,      try sym("VarTilemapBuf") & 0xFFFF,
        try sym("VarCamY") & 0xFFFF,               try sym("VarCamX") & 0xFFFF,
        number,                                    sample_slots,
        try sym("VarCollWeapon") & 0xFFFF,         try sym("VarCollEnemy") & 0xFFFF,
        try sym("VarCollWeaponDir") & 0xFFFF,
        try sym("VarAlphaStun") & 0xFFFF,          try sym("VarGammaStun") & 0xFFFF,
        try sym("VarZetaStun") & 0xFFFF,
        @as(u8, @truncate(try sym("ConstAlphaStunN"))),
        try sym("VarSamusX") & 0xFFFF,
        try sym("VarSpawnReload") & 0xFFFF,
        if (by_number) "true" else "false",
        try sym("VarCutscene") & 0xFFFF,           if (freeze) "true" else "false",
        if (tiles_end) "true" else "false",
        maxCartEntries(tiles_end),                 cart_record_bytes,
    });
    for (sample_fields) |f| try w.print("{d},", .{f});
    try w.print("}}\nlocal GLOBALS = {{", .{});
    for (globals) |g| try w.print("0x{X:0>4},", .{try sym(g.sym) & 0xFFFF});
    try w.print("}}\nlocal SEED = {{", .{});
    for (seed) |b| try w.print("{d},", .{b});
    // Keyed by commit: commit 1 is the top of tick 0.
    try w.print("}}\nlocal HITS = {{", .{});
    for (hits) |h| if (!h.late) try w.print("[{d}]={{{d},{d}}},", .{ @as(usize, h.tick) + 1, h.weapon, h.dir });
    // `Hit.late`, keyed like HITS, with the label it is written at. One table,
    // so the script's locals do not grow.
    try w.print("}}\nlocal LATE = {{at=0x{X:0>6},", .{try sym("MainLoop_afterContact")});
    for (hits) |h| if (h.late) try w.print("[{d}]={{{d},{d}}},", .{ @as(usize, h.tick) + 1, h.weapon, h.dir });
    try w.print("}}\nlocal COINS = {{", .{});
    for (coins) |c| try w.print("{{{d},{d}}},", .{ c.mask, c.value });
    // The sweep, keyed the way HITS is: entry 1 is the top of tick 0. Empty for
    // every case that lets the game keep its own camera.
    // Keyed like HITS: entry 1 is the top of tick 0.
    try w.print("}}\nlocal RESETS = {{", .{});
    for (resets) |at| try w.print("[{d}]=true,", .{@as(usize, at) + 1});
    // `Case.fire`, keyed like HITS: entry 1 is the top of tick 0. Each entry
    // is the pad table itself, every span's keys on that tick together.
    try w.print("}}\nlocal FIRE = {{", .{});
    var last: usize = 0;
    for (fire) |sp| last = @max(last, sp.to);
    for (0..last) |t| {
        const k = pressed(fire, t);
        if (@as(u8, @bitCast(k)) == 0) continue;
        var kb: [96]u8 = undefined;
        try w.print("[{d}]={{{s}}},", .{ t + 1, oracle.mesenKeys(k, &kb) });
    }
    try w.print("}}\nlocal SWEEPCAM = {{", .{});
    for (sweep_cam) |x| try w.print("{d},", .{x});
    try w.print("}}\nlocal SWEEPSAMUS = {{", .{});
    for (sweep_samus) |x| try w.print("{d},", .{x});
    // `Case.dividers`: the Game Boy's reads, in order, and where the cart's
    // are. One table a site, so the script's locals do not grow with them.
    try w.print("}}\nlocal DIVHIGH = 0x{X:0>4}\nlocal DIVSITES, DIVS = {{", .{(try sym("VarDivClock") & 0xFFFF) + 1});
    for (divs.sites[0..divs.n]) |x| try w.print("0x{X:0>6},", .{x});
    try w.print("}}, {{", .{});
    for (divs.vals[0..divs.n]) |vals| {
        try w.print("{{", .{});
        for (vals) |x| try w.print("{d},", .{x});
        try w.print("}},", .{});
    }
    try w.print(
        \\}}
        \\
        \\-- `Case.dividers`: each site's Game Boy reads, handed to its cart read, in order.
        \\for s = 1, #DIVSITES do
        \\  local d, vals, at = 0, DIVS[s], DIVSITES[s]
        \\  emu.addMemoryCallback(function()
        \\    d = d + 1
        \\    local v = vals[d]
        \\    if v ~= nil then emu.write(DIVHIGH, v, wram) end
        \\  end, emu.callbackType.exec, at, at, emu.cpuType.snes, emu.memType.snesMemory)
        \\end
        \\
        \\local i = 0
        \\local hold = {{}}
        \\local k, prevStun, prevStun2, prevStun3 = 0, 0, 0, 0
        \\local prev, n, full = nil, 0, false
        \\
        \\local function flush()
        \\  emu.write(0, full and 0xFF or (n & 0xFF), sram)
        \\  emu.write(1, full and 0xFF or (n >> 8), sram)
        \\end
        \\
        \\emu.addMemoryCallback(function()
        \\  i = i + 1
        \\  -- The pad for this tick, at the commit that is the top of it: the
        \\  -- segment rung's relation. See `enemy_oracle.Case.fire`.
        \\  hold = FIRE[i] or {{}}
        \\  -- The camera as this tick starts, captured *before* the sweep writes
        \\  -- the next tick's: the row below is the previous tick's state, and the
        \\  -- Game Boy reads its camera at that same point. Nothing else in this
        \\  -- callback touches it, so a case without a sweep reads the same byte
        \\  -- either way.
        \\  local camy0, camx0 = emu.read(CAMY, wram), emu.read(CAMX, wram)
        \\  local h = HITS[i]
        \\  if h ~= nil then
        \\    emu.write(COLLW, h[1], wram)
        \\    emu.write(COLLE, 0, wram)
        \\    emu.write(COLLE + 1, 0, wram)
        \\    emu.write(COLLD, h[2], wram)
        \\  end
        \\  -- The sweep, before the seed's own arm so tick 0 is driven too: the
        \\  -- Game Boy writes these four bytes at this same point of this same
        \\  -- tick. See `enemy_oracle.Case.sweep`.
        \\  if FREEZE then emu.write(CUTSCENE, 1, wram) end
        \\  -- The room reset, at the same tick, before the same tick's frame runs.
        \\  if RESETS[i] then emu.write(RELOAD, 2, wram) end
        \\  local sc = SWEEPCAM[i]
        \\  if sc ~= nil then
        \\    emu.write(CAMX, sc & 0xFF, wram)
        \\    emu.write(CAMX + 1, sc >> 8, wram)
        \\    local ss = SWEEPSAMUS[i]
        \\    emu.write(SAMUSX, ss & 0xFF, wram)
        \\    emu.write(SAMUSX + 1, ss >> 8, wram)
        \\  end
        \\  if i == 1 then
        \\    for k = 0, 16 * 32 - 1 do emu.write(SLOTS + k, 0xFF, wram) end
        \\    for k = 1, 32 do emu.write(SLOTS + k - 1, SEED[k], wram) end
        \\    emu.write(SPAWNFLAGS + NUMBER, 1, wram)
        \\    emu.write(TOTAL, 1, wram)
        \\    emu.write(ACTIVE, 1, wram)
        \\    emu.write(OFFSCR, 0, wram)
        \\    emu.write(ENFRAME, 0, wram)
        \\    emu.write(ENSAME, 0, wram)
        \\    emu.write(ENLEFT, 0, wram)
        \\    emu.write(UNHANDLED, 0, wram)
        \\    emu.write(UNHANDLED + 1, 0, wram)
        \\    -- The terrain the AI is about to walk on, after the count.
        \\    for k = 0, 1023 do emu.write({d} + k, emu.read(TILEMAP + k * 2, wram), sram) end
        \\    flush()
        \\    return
        \\  end
        \\  -- The coin, before the record: see `enemy_oracle.Coin`.
        \\  local st, st2, st3 = emu.read(STUN, wram), emu.read(STUN2, wram), emu.read(STUN3, wram)
        \\  if (st == STUN_N and prevStun ~= STUN_N) or (st2 == STUN_N and prevStun2 ~= STUN_N) or (st3 == STUN_N and prevStun3 ~= STUN_N) then
        \\    k = k + 1
        \\    local c = COINS[k]
        \\    if c ~= nil then
        \\      local v = emu.read(SLOTS + 8, wram)
        \\      emu.write(SLOTS + 8, (v & (0xFF ~ c[1])) | c[2], wram)
        \\    end
        \\  end
        \\  prevStun, prevStun2, prevStun3 = st, st2, st3
        \\  local r = {{}}
        \\  if BYNUMBER then
        \\    -- Whichever slot holds this case's spawn number, or all-$FF when
        \\    -- none does. See `enemy_oracle.Case.by_number`.
        \\    local at = nil
        \\    for slot = 0, 15 do
        \\      local base = SLOTS + slot * 32
        \\      if emu.read(base, wram) ~= 0xFF and emu.read(base + 0x1D, wram) == NUMBER then at = base; break end
        \\    end
        \\    for k = 1, #FIELDS do r[#r + 1] = at and emu.read(at + FIELDS[k], wram) or 0xFF end
        \\    for k = #FIELDS + 1, #FIELDS * NSLOTS do r[#r + 1] = 0xFF end
        \\  else
        \\    for slot = 0, NSLOTS - 1 do
        \\      for k = 1, #FIELDS do r[#r + 1] = emu.read(SLOTS + slot * 32 + FIELDS[k], wram) end
        \\    end
        \\  end
        \\  for k = 1, #GLOBALS do r[#r + 1] = emu.read(GLOBALS[k], wram) end
        \\  r[#r + 1] = emu.read(UNHANDLED, wram)
        \\  r[#r + 1] = emu.read(UNHANDLED + 1, wram)
        \\  r[#r + 1] = camy0
        \\  r[#r + 1] = camx0
        \\  local same = prev ~= nil
        \\  if same then
        \\    for k = 1, RB do if r[k] ~= prev[k] then same = false; break end end
        \\  end
        \\  if not same and not full then
        \\    if n >= MAXN then
        \\      full = true
        \\    else
        \\      local at = {d} + n * (RB + 2)
        \\      local tick = i - 2
        \\      emu.write(at, tick & 0xFF, sram)
        \\      emu.write(at + 1, tick >> 8, sram)
        \\      for k = 1, RB do emu.write(at + 1 + k, r[k], sram) end
        \\      n = n + 1
        \\    end
        \\  end
        \\  prev = r
        \\  if i - 1 >= FRAMES then
        \\    if TILESEND then
        \\      for k = 0, 1023 do emu.write({d} + k, emu.read(TILEMAP + k * 2, wram), sram) end
        \\    end
        \\    flush()
        \\    emu.stop(0)
        \\  end
        \\end, emu.callbackType.exec, COMMIT, COMMIT, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\-- `Hit.late`: after Samus's contact test, in the tick the commit began.
        \\emu.addMemoryCallback(function()
        \\  local h = LATE[i]
        \\  if h ~= nil then
        \\    emu.write(COLLW, h[1], wram)
        \\    emu.write(COLLE, 0, wram)
        \\    emu.write(COLLE + 1, 0, wram)
        \\    emu.write(COLLD, h[2], wram)
        \\  end
        \\end, emu.callbackType.exec, LATE.at, LATE.at, emu.cpuType.snes, emu.memType.snesMemory)
        \\
        \\emu.addEventCallback(function()
        \\  emu.setInput(hold, 0)
        \\end, emu.eventType.inputPolled)
        \\
        \\local watchdog = 0
        \\emu.addEventCallback(function()
        \\  watchdog = watchdog + 1
        \\  if i == 0 and watchdog > 120 then emu.stop(1) end
        \\end, emu.eventType.endFrame)
        \\
    , .{ cart_tiles_at, cart_entries_at, cart_tiles_end_at });
}

pub const CartRun = struct {
    samples: []Sample,
    camera: [][2]u8,
    tiles: [1024]u8,
    tiles_end: [1024]u8,
    /// `!EnUnhandledAi` after the last tick: the first AI the cart was handed and
    /// has no routine for. The case's own AI here means it was never run; any
    /// other is a neighbour the loader brought in, which is not this case's.
    unhandled_ai: u16,
    code: u8,

    pub fn deinit(self: *CartRun, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        allocator.free(self.camera);
    }
};

/// Blank `ai`'s row in a built cart's `AiTable`, so the dispatch records it as
/// unhandled. The fault this rung has to catch, applied to the bytes the cart
/// actually runs rather than to a rebuilt engine.
pub fn blankAiRow(cart: []u8, ai: u16) Error!void {
    for (ai_tables) |t| {
        const table = inject.symbolOffset(t[0]) orelse return Error.MissingSymbol;
        const end = inject.symbolOffset(t[1]) orelse return Error.MissingSymbol;
        if (!std.mem.eql(u8, cart[table..end], inject.image[table..end])) return Error.NotTheImage;
        var at = table;
        while (at < end) : (at += 4) {
            const key = @as(u16, cart[at]) | (@as(u16, cart[at + 1]) << 8);
            if (key == ai) {
                cart[at] = 0;
                cart[at + 1] = 0;
                return;
            }
        }
    }
    return Error.MissingSymbol;
}

/// The two dispatch tables, bank 0's and (1.0 Step 11, bank 0 being full)
/// bank 1's. Both are (Game Boy address, routine) rows of four bytes.
pub const ai_tables = [_][2][]const u8{
    .{ "AiTable", "AiTableEnd" },
    .{ "AiTableFar", "AiTableFarEnd" },
};

pub fn runCart(
    allocator: std.mem.Allocator,
    io: std.Io,
    cart: []const u8,
    seed: [slot_bytes]u8,
    number: u8,
    frames: u16,
    hits: []const Hit,
    coins: []const Coin,
    sweep_cam: []const u16,
    sweep_samus: []const u16,
    resets: []const u16,
    fire: []const Span,
    by_number: bool,
    freeze: bool,
    tiles_end: bool,
    divs: DivHand,
    mesen_path: []const u8,
    home: []const u8,
) !CartRun {
    var run = try startCart(allocator, io, cart, seed, number, frames, hits, coins, sweep_cam, sweep_samus, resets, fire, by_number, freeze, tiles_end, divs, stem, mesen_path, home);
    return finishCart(allocator, io, &run);
}

/// One cart run in flight: `startCart` has written its files and spawned
/// Mesen2, and `finishCart` waits for it and reads what it saved.
///
/// **1.0 Step 12: split so a case's runs, and several cases, go at once.** The
/// rung had grown to 45 cases of two or three runs each, one after another, and
/// the gate past its fifteen minutes. Each run is its own process with its own
/// files, named by `name`, as the scenario rung's are.
pub const Started = struct {
    child: std.process.Child,
    srm: []u8,
    frames: u16,
};

pub fn startCart(
    allocator: std.mem.Allocator,
    io: std.Io,
    cart: []const u8,
    seed: [slot_bytes]u8,
    number: u8,
    frames: u16,
    hits: []const Hit,
    coins: []const Coin,
    sweep_cam: []const u16,
    sweep_samus: []const u16,
    resets: []const u16,
    fire: []const Span,
    by_number: bool,
    freeze: bool,
    tiles_end: bool,
    divs: DivHand,
    name: []const u8,
    mesen_path: []const u8,
    home: []const u8,
) !Started {
    const stamped = try allocator.dupe(u8, cart);
    defer allocator.free(stamped);
    try snes_trace.stampSramOf(stamped, cart_sram_size_byte);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer dir.close(io);
    const cart_file = try std.fmt.allocPrint(allocator, "{s}.sfc", .{name});
    defer allocator.free(cart_file);
    const lua_file = try std.fmt.allocPrint(allocator, "{s}.lua", .{name});
    defer allocator.free(lua_file);
    try dir.writeFile(io, .{ .sub_path = cart_file, .data = stamped });

    var lua: std.Io.Writer.Allocating = .init(allocator);
    defer lua.deinit();
    try writeLua(&lua.writer, seed, number, frames, hits, coins, sweep_cam, sweep_samus, resets, fire, by_number, freeze, tiles_end, divs);
    try dir.writeFile(io, .{ .sub_path = lua_file, .data = lua.written() });

    const srm = try snes_trace.savePath(allocator, io, home, name);
    errdefer allocator.free(srm);
    // A stale file from an earlier case would read as this one.
    std.Io.Dir.cwd().deleteFile(io, srm) catch {};

    const cart_path = try std.fmt.allocPrint(allocator, out_dir ++ "/{s}", .{cart_file});
    defer allocator.free(cart_path);
    const lua_path = try std.fmt.allocPrint(allocator, out_dir ++ "/{s}", .{lua_file});
    defer allocator.free(lua_path);
    const child = try std.process.spawn(io, .{
        .argv = &.{ mesen_path, cart_path, "--testrunner", lua_path, "--timeout=60" },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return .{ .child = child, .srm = srm, .frames = frames };
}

pub fn finishCart(allocator: std.mem.Allocator, io: std.Io, run: *Started) !CartRun {
    defer allocator.free(run.srm);
    const frames = run.frames;
    const term = try run.child.wait(io);
    const code: u8 = if (term == .exited) @truncate(term.exited) else 255;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, run.srm, allocator, .limited(cart_sram_bytes * 2)) catch
        return Error.NoSaveFile;
    defer allocator.free(bytes);
    if (bytes.len < cart_sram_bytes) return Error.ShortSaveFile;
    const count = std.mem.readInt(u16, bytes[0..2], .little);
    if (count == 0xFFFF) return Error.TooManyRecords;
    if (count == 0) return Error.ShortSaveFile;

    const samples = try allocator.alloc(Sample, frames);
    errdefer allocator.free(samples);
    const camera = try allocator.alloc([2]u8, frames);
    errdefer allocator.free(camera);
    // Each entry holds from its tick until the next entry's.
    var e: usize = 0;
    var row: []const u8 = undefined;
    const n = @sizeOf(Sample);
    for (samples, camera, 0..) |*s, *cam, f| {
        while (e < count) {
            const at = cart_entries_at + e * cart_entry_bytes;
            if (std.mem.readInt(u16, bytes[at..][0..2], .little) > f) break;
            row = bytes[at + 2 ..][0..cart_record_bytes];
            e += 1;
        }
        if (e == 0) return Error.ShortSaveFile;
        @memcpy(s, row[0..n]);
        cam.* = .{ row[n + 2], row[n + 3] };
    }
    return .{
        .samples = samples,
        .camera = camera,
        .tiles = bytes[cart_tiles_at..][0..1024].*,
        .tiles_end = bytes[cart_tiles_end_at..][0..1024].*,
        .unhandled_ai = @as(u16, row[n]) | (@as(u16, row[n + 1]) << 8),
        .code = code,
    };
}

/// One slot's bytes out of a record.
pub const SlotSample = [sample_fields.len]u8;

/// One slot's history with its runs of identical records collapsed to one. See
/// the file comment for why the comparison is over these rather than over
/// frames.
///
/// **Per slot, and that is measured rather than tidy.** With more than one
/// live slot the original sometimes finishes the later slots on the next frame
/// -- the `rLY` budget at 02:$4148, which the port deliberately does not have
/// -- so two slots' passes land one frame apart on one machine and together on
/// the other. Collapsed together that is a difference; collapsed apart each
/// slot's history is still the same history. Measured 2026-09-13 on the pipe
/// bug's room: a neighbouring spawner's counter a frame early on the cart at
/// frames 100, 108 and 116 and nowhere else.
pub fn passes(allocator: std.mem.Allocator, samples: []const Sample, slot: usize) ![]SlotSample {
    var out: std.ArrayList(SlotSample) = .empty;
    errdefer out.deinit(allocator);
    for (samples) |rec| {
        const s: SlotSample = rec[slot * sample_fields.len ..][0..sample_fields.len].*;
        if (out.items.len > 0 and std.mem.eql(u8, &out.items[out.items.len - 1], &s)) continue;
        try out.append(allocator, s);
    }
    return out.toOwnedSlice(allocator);
}

pub const Histories = [sample_slots][]SlotSample;

/// One global's history, its runs collapsed. See `globals`.
pub fn globalPasses(allocator: std.mem.Allocator, samples: []const Sample, g: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (samples) |rec| {
        const v = rec[slots_bytes + g];
        if (out.items.len > 0 and out.items[out.items.len - 1] == v) continue;
        try out.append(allocator, v);
    }
    return out.toOwnedSlice(allocator);
}

pub const GlobalHistories = [globals.len][]u8;

pub fn globalHistories(allocator: std.mem.Allocator, samples: []const Sample) !GlobalHistories {
    var h: GlobalHistories = @splat(&.{});
    errdefer for (h) |x| allocator.free(x);
    for (&h, 0..) |*x, g| x.* = try globalPasses(allocator, samples, g);
    return h;
}

/// The first global whose two histories differ, and the entry they differ at.
/// A shorter history is a difference here, unlike a slot's: a global has no
/// pass parity to excuse a missing last step.
pub const GlobalDiff = struct { global: usize, at: usize };

/// **A frozen case does not grade the cutscene flag** (1.0 Step 14): the
/// fixture writes it every tick (`Case.freeze`), so its history is the
/// fixture's, and an AI that clears it -- the Gamma's molt ends so -- shows the
/// clear on whichever machine samples before the rewrite. `freeze` names it.
pub fn compareGlobals(gb: GlobalHistories, cart: GlobalHistories, freeze: bool) ?GlobalDiff {
    for (gb, cart, 0..) |g, k, i| {
        if (freeze and globals[i].gb == gb_cutscene) continue;
        const n = @min(g.len, k.len);
        for (0..n) |j| {
            if (g[j] != k[j]) return .{ .global = i, .at = j };
        }
        if (g.len != k.len) return .{ .global = i, .at = n };
    }
    return null;
}

pub fn histories(allocator: std.mem.Allocator, samples: []const Sample) !Histories {
    var h: Histories = undefined;
    var made: usize = 0;
    errdefer for (h[0..made]) |x| allocator.free(x);
    for (&h, 0..) |*x, slot| {
        x.* = try passes(allocator, samples, slot);
        made += 1;
    }
    return h;
}

pub fn freeHistories(allocator: std.mem.Allocator, h: Histories) void {
    for (h) |x| allocator.free(x);
}

/// How many distinct values the state byte took: an AI whose history never
/// leaves one state has been graded on one arm of it.
pub fn states(p: []const SlotSample) usize {
    var seen: [256]bool = @splat(false);
    var n: usize = 0;
    for (p) |x| {
        if (!seen[x[8]]) n += 1;
        seen[x[8]] = true;
    }
    return n;
}

/// Tiles the two maps disagree on inside the Game Boy's view -- the 160x144
/// window SCX/SCY put on the screen, plus the tile each edge cuts. An enemy
/// outside it is offscreen and deactivated, so this is the terrain an AI can be
/// graded on.
pub fn viewDiffers(gb: *const [1024]u8, cart: *const [1024]u8, scx: u8, scy: u8) usize {
    var n: usize = 0;
    var r: usize = 0;
    while (r <= 144 / 8 + 1) : (r += 1) {
        var col: usize = 0;
        while (col <= 160 / 8 + 1) : (col += 1) {
            const ty = ((@as(usize, scy) >> 3) + r) & 31;
            const tx = ((@as(usize, scx) >> 3) + col) & 31;
            n += @intFromBool(gb[ty * 32 + tx] != cart[ty * 32 + tx]);
        }
    }
    return n;
}

/// Whether a `by_number` history loses the record and gets it back: an empty
/// entry with a live one on each side of it.
///
/// **The rung's own "it graded something" check.** A sweep that never took the
/// enemy far enough to be deleted, or that came back on the wrong seam and never
/// reloaded, would agree with the Game Boy on a history that says nothing about
/// the mechanism -- and would keep agreeing after the mechanism was broken.
pub fn leftAndCameBack(p: []const SlotSample) bool {
    var live_before = false;
    var gone = false;
    for (p) |x| {
        const empty = x[0] == 0xFF;
        if (!empty and !gone) live_before = true;
        if (empty and live_before) gone = true;
        if (!empty and gone) return true;
    }
    return false;
}

/// How many passes changed the direction byte: a crawler that never turns has
/// not been asked about corners.
pub fn turns(p: []const SlotSample) usize {
    var n: usize = 0;
    for (1..p.len) |i| n += @intFromBool(p[i][6] != p[i - 1][6]);
    return n;
}

pub const Verdict = struct {
    /// Slot 0's entries compared: the shorter of the two histories.
    compared: usize,
    /// The slot the first difference is in.
    slot: usize = 0,
    /// The first entry that differs, or null if every compared entry agrees.
    first_diff: ?usize,
    gb_len: usize,
    cart_len: usize,

    pub fn matched(self: Verdict) bool {
        return self.first_diff == null;
    }

    /// Whether a faulted cart was told apart from the Game Boy. **A shorter
    /// history is a caught fault**, not an agreeing one: `compare` checks the
    /// common prefix, and a missile door whose AI never runs has a one-entry
    /// history that is a prefix of everything. That hole let the first door
    /// case report its fault as agreeing, which is how it was found.
    pub fn caught(self: Verdict) bool {
        return !self.matched() or self.cart_len + 1 < self.gb_len;
    }
};

pub fn compare(gb: []const SlotSample, cart: []const SlotSample) Verdict {
    const n = @min(gb.len, cart.len);
    for (0..n) |i| {
        if (!std.mem.eql(u8, &gb[i], &cart[i])) {
            return .{ .compared = n, .first_diff = i, .gb_len = gb.len, .cart_len = cart.len };
        }
    }
    return .{ .compared = n, .first_diff = null, .gb_len = gb.len, .cart_len = cart.len };
}

/// Whether a slot ever held a child of slot 0 on the Game Boy: a spawn flag of
/// `$00`, which is slot 0's link (see `SlotLink`). **Only those slots are
/// graded beside slot 0.** Anything else in the other slots is a neighbour the
/// spawn walk loaded, and both the walk's timing and the `rLY` budget can put
/// a neighbour a frame apart on the two machines while the camera is moving --
/// measured on the Gullugg's and the pipe bug's rooms, and recorded in
/// `docs/bug_tracker.md` -- which is a finding about those mechanisms and not
/// about the AI a case seeds.
pub fn childOfSlot0(gb: Histories, slot: usize, flag: u8) bool {
    if (slot == 0) return false;
    for (gb[slot]) |x| {
        if (x[0] != 0xFF and x[9] == flag) return true;
    }
    return false;
}

/// Slot 0 and its children; the verdict is slot 0's unless a child differs, in
/// which case it is that slot's.
pub fn compareAll(gb: Histories, cart: Histories, flag: u8) Verdict {
    const first = compare(gb[0], cart[0]);
    if (!first.matched()) return first;
    for (1..sample_slots) |slot| {
        if (!childOfSlot0(gb, slot, flag)) continue;
        var v = compare(gb[slot], cart[slot]);
        if (!v.matched()) {
            v.slot = slot;
            v.compared = first.compared;
            return v;
        }
    }
    return first;
}

/// One case, graded: the honest cart against the Game Boy, and the cart with
/// the AI's `AiTable` row blanked, which has to disagree.
pub const CaseReport = struct {
    case: Case,
    sprite: u8 = 0,
    gb: Histories = @splat(&.{}),
    cart: Histories = @splat(&.{}),
    /// The per-frame records both histories were collapsed from, for when the
    /// collapsed ones disagree and the question is which frame.
    gb_raw: []Sample = &.{},
    cart_raw: []Sample = &.{},
    gb_cam: [][2]u8 = &.{},
    cart_cam: [][2]u8 = &.{},
    gb_globals: GlobalHistories = @splat(&.{}),
    cart_globals: GlobalHistories = @splat(&.{}),
    global_diff: ?GlobalDiff = null,
    /// Frames on which the two cameras' pixel bytes differ. Nonzero is a
    /// finding about the room's camera, not about the AI.
    camera_diff: usize = 0,
    verdict: ?Verdict = null,
    fault: ?Verdict = null,
    /// Whether `Case.behaviour`'s cart was told apart, in a slot or a global.
    /// Null for a case with no such fault.
    behaviour_caught: ?bool = null,
    unhandled_ai: u16 = 0,
    code: u8 = 0,
    no_emulator: bool = false,
    no_boot: bool = false,
    /// Tiles in view the cart's map disagrees with the Game Boy's on. Nonzero
    /// is a finding about the room, not about the AI, and is reported as such.
    world_diff: usize = 0,
    /// `Case.tiles_end`: tiles in view the two maps disagree on after the last
    /// tick. Zero for a case without it.
    end_diff: usize = 0,

    pub fn ok(self: CaseReport) bool {
        if (self.no_boot) return false;
        if (self.gb[0].len < self.case.min_passes) return false;
        if (self.no_emulator) return true;
        const v = self.verdict orelse return false;
        const f = self.fault orelse return false;
        if (self.case.by_number and !leftAndCameBack(self.gb[0])) return false;
        return self.world_diff == 0 and self.end_diff == 0 and self.camera_diff == 0 and v.matched() and self.global_diff == null and
            v.compared >= self.case.min_passes and v.cart_len + 1 >= v.gb_len and
            self.unhandled_ai != self.case.ai and f.caught() and
            (self.case.behaviour == null or self.behaviour_caught == true);
    }

    pub fn deinit(self: *CaseReport, allocator: std.mem.Allocator) void {
        freeHistories(allocator, self.gb);
        freeHistories(allocator, self.cart);
        allocator.free(self.gb_raw);
        allocator.free(self.cart_raw);
        allocator.free(self.gb_cam);
        allocator.free(self.cart_cam);
        for (self.gb_globals) |x| allocator.free(x);
        for (self.cart_globals) |x| allocator.free(x);
    }
};

pub fn gradeCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    set: convert.Set,
    c: Case,
    mesen_path: []const u8,
    home: []const u8,
) !CaseReport {
    var f = try startCase(allocator, io, rom, set, c, stem, mesen_path, home);
    return finishCase(allocator, io, &f);
}

/// One case in flight: the Game Boy's run done and the cart's runs started,
/// all at once -- the honest cart, the faulted one and the behaviour fault's.
/// See `Started`.
pub const InFlight = struct {
    rep: CaseReport,
    gb: ?GbRun = null,
    honest: ?Started = null,
    faulted: ?Started = null,
    broken: ?Started = null,
};

/// `name` makes the runs' files this case's own: see `Started`.
pub fn startCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    set: convert.Set,
    c: Case,
    name: []const u8,
    mesen_path: []const u8,
    home: []const u8,
) !InFlight {
    var f: InFlight = .{ .rep = .{ .case = c } };
    const rep = &f.rep;
    const found = (try snes_screen.bootForAt(allocator, rom, c.bank - 9, c.cell, c.count)) orelse {
        rep.no_boot = true;
        return f;
    };
    f.gb = try runGb(allocator, rom, c, found.boot);
    const gb = &f.gb.?;
    rep.sprite = gb.seed[0x03];
    rep.gb = try histories(allocator, gb.samples);
    rep.gb_raw = try allocator.dupe(Sample, gb.samples);
    rep.gb_cam = try allocator.dupe([2]u8, gb.camera);
    rep.gb_globals = try globalHistories(allocator, gb.samples);

    var diag: inject.Diagnosis = .{};
    var cart = try inject.build(allocator, set, cartBoot(found.boot, gb.*), &diag);
    defer cart.deinit();

    if (mesen_path.len == 0) {
        rep.no_emulator = true;
        return f;
    }
    const number = gb.seed[0x1D];
    const divs = try divHand(c, gb);
    const coins = gb.coins[0..gb.coin_n];
    const run_name = struct {
        fn of(a: std.mem.Allocator, n: []const u8, suffix: []const u8) ![]u8 {
            return std.fmt.allocPrint(a, "{s}{s}", .{ n, suffix });
        }
    }.of;

    const honest_name = try run_name(allocator, name, "");
    defer allocator.free(honest_name);
    f.honest = try startCart(allocator, io, cart.bytes, gb.seed, number, c.frames, c.hits, coins, gb.sweep_cam, gb.sweep_samus, c.resets, c.fire, c.by_number, c.freeze, c.tiles_end, divs, honest_name, mesen_path, home);

    const faulted_bytes = try allocator.dupe(u8, cart.bytes);
    defer allocator.free(faulted_bytes);
    try blankAiRow(faulted_bytes, c.ai);
    const faulted_name = try run_name(allocator, name, "-fault");
    defer allocator.free(faulted_name);
    f.faulted = try startCart(allocator, io, faulted_bytes, gb.seed, number, c.frames, c.hits, coins, gb.sweep_cam, gb.sweep_samus, c.resets, c.fire, c.by_number, c.freeze, c.tiles_end, divs, faulted_name, mesen_path, home);

    if (c.behaviour) |p| {
        const patched = try allocator.dupe(u8, cart.bytes);
        defer allocator.free(patched);
        const at = (inject.symbolOffset(p.label) orelse return Error.MissingSymbol) + p.offset;
        if (std.mem.eql(u8, patched[at..][0..p.bytes.len], p.bytes)) return Error.NotTheImage;
        @memcpy(patched[at..][0..p.bytes.len], p.bytes);
        const broken_name = try run_name(allocator, name, "-behaviour");
        defer allocator.free(broken_name);
        f.broken = try startCart(allocator, io, patched, gb.seed, number, c.frames, c.hits, coins, gb.sweep_cam, gb.sweep_samus, c.resets, c.fire, c.by_number, c.freeze, c.tiles_end, divs, broken_name, mesen_path, home);
    }
    return f;
}

/// Wait for a case's runs and grade them against the Game Boy's.
pub fn finishCase(allocator: std.mem.Allocator, io: std.Io, f: *InFlight) !CaseReport {
    defer if (f.gb) |*gb| gb.deinit(allocator);
    const rep = &f.rep;
    const c = rep.case;
    const gb = if (f.gb) |*g| g else return rep.*;
    var honest = try finishCart(allocator, io, &(f.honest orelse return rep.*));
    defer honest.deinit(allocator);
    rep.cart = try histories(allocator, honest.samples);
    rep.cart_raw = try allocator.dupe(Sample, honest.samples);
    rep.cart_cam = try allocator.dupe([2]u8, honest.camera);
    for (gb.camera, honest.camera) |g, k| rep.camera_diff += @intFromBool(!std.mem.eql(u8, &g, &k));
    rep.verdict = compareAll(rep.gb, rep.cart, c.child_flag);
    rep.cart_globals = try globalHistories(allocator, honest.samples);
    rep.global_diff = compareGlobals(rep.gb_globals, rep.cart_globals, c.freeze);
    rep.unhandled_ai = honest.unhandled_ai;
    rep.world_diff = viewDiffers(&gb.tiles, &honest.tiles, gb.scx, gb.scy);
    if (c.tiles_end) rep.end_diff = viewDiffers(&gb.tiles_end, &honest.tiles_end, gb.scx_end, gb.scy_end);
    rep.code = honest.code;

    var faulted = try finishCart(allocator, io, &f.faulted.?);
    defer faulted.deinit(allocator);
    const fault_passes = try histories(allocator, faulted.samples);
    defer freeHistories(allocator, fault_passes);
    rep.fault = compareAll(rep.gb, fault_passes, c.child_flag);

    if (f.broken) |*b| {
        var broken = try finishCart(allocator, io, b);
        defer broken.deinit(allocator);
        const broken_passes = try histories(allocator, broken.samples);
        defer freeHistories(allocator, broken_passes);
        const broken_globals = try globalHistories(allocator, broken.samples);
        defer for (broken_globals) |x| allocator.free(x);
        rep.behaviour_caught = compareAll(rep.gb, broken_passes, c.child_flag).caught() or
            compareGlobals(rep.gb_globals, broken_globals, c.freeze) != null or
            (c.tiles_end and viewDiffers(&gb.tiles_end, &broken.tiles_end, gb.scx_end, gb.scy_end) != 0);
    }
    return rep.*;
}

/// Grade `cases` with up to `width` in flight at once, each case's files named
/// by its index. The reports come back in `cases`' order.
pub fn gradeCases(
    allocator: std.mem.Allocator,
    io: std.Io,
    rom: []const u8,
    set: convert.Set,
    cases_in: []const Case,
    width: usize,
    mesen_path: []const u8,
    home: []const u8,
    reps: []CaseReport,
) !void {
    const flight = try allocator.alloc(InFlight, cases_in.len);
    defer allocator.free(flight);
    var next_done: usize = 0;
    for (cases_in, 0..) |c, i| {
        if (i - next_done == width) {
            reps[next_done] = try finishCase(allocator, io, &flight[next_done]);
            next_done += 1;
        }
        const name = try std.fmt.allocPrint(allocator, stem ++ "{d}", .{i});
        defer allocator.free(name);
        flight[i] = try startCase(allocator, io, rom, set, c, name, mesen_path, home);
    }
    while (next_done < cases_in.len) : (next_done += 1) {
        reps[next_done] = try finishCase(allocator, io, &flight[next_done]);
    }
}

/// The cart's half of `Case.dividers`: each site's address and the Game Boy's reads.
fn divHand(c: Case, gb: *const GbRun) !DivHand {
    var h: DivHand = .{ .n = c.dividers.len };
    for (c.dividers, 0..) |d, i| {
        h.sites[i] = try sym(d.cart);
        h.vals[i] = gb.divs[i][0..gb.div_n[i]];
    }
    return h;
}

/// Both machines' per-frame records side by side, `count` frames from `first`.
pub fn printRaw(out: *std.Io.Writer, rep: CaseReport, first: usize, count: usize) !void {
    const n = @min(rep.gb_raw.len, rep.cart_raw.len);
    try out.print("  frame slot  gb: st  y  x spr at gv df ct sa fl  cy cx   cart: st  y  x spr at gv df ct sa fl  cy cx   gb: pdt st cut stn fgt rl ds  cart: pdt st cut stn fgt rl ds\n", .{});
    for (first..@min(n, first + count)) |i| {
        for (0..sample_slots) |slot| {
            const g = rep.gb_raw[i][slot * sample_fields.len ..][0..sample_fields.len];
            const k = rep.cart_raw[i][slot * sample_fields.len ..][0..sample_fields.len];
            if (slot != 0 and g[0] == 0xFF and k[0] == 0xFF) continue;
            try out.print("  {d:>5} {d:>4}      ", .{ i, slot });
            for (g) |b| try out.print("{X:0>2} ", .{b});
            try out.print(" {X:0>2} {X:0>2}        ", .{ rep.gb_cam[i][0], rep.gb_cam[i][1] });
            for (k) |b| try out.print("{X:0>2} ", .{b});
            try out.print(" {X:0>2} {X:0>2}", .{ rep.cart_cam[i][0], rep.cart_cam[i][1] });
            if (slot == 0) {
                try out.print("      ", .{});
                for (rep.gb_raw[i][slots_bytes..]) |b| try out.print(" {X:0>2}", .{b});
                try out.print("       ", .{});
                for (rep.cart_raw[i][slots_bytes..]) |b| try out.print(" {X:0>2}", .{b});
            }
            try out.print("\n", .{});
        }
    }
}

/// One line per case, and the disagreement's neighbourhood when there is one.
pub fn printCase(out: *std.Io.Writer, rep: CaseReport, indent: []const u8) !void {
    const c = rep.case;
    if (rep.no_boot) {
        try out.print("{s}{s}: no boot record for ${X}:${X:0>2}\n", .{ indent, c.name, c.bank, c.cell });
        return;
    }
    if (rep.no_emulator) {
        try out.print("{s}{s}: {d} passes on the Game Boy; not compared: no emulator (set MESEN)\n", .{ indent, c.name, rep.gb[0].len });
        return;
    }
    const v = rep.verdict.?;
    try out.print("{s}{s}: ${X}:${X:0>2} sprite ${X:0>2}, {d} of {d} passes agree ({d} states, {d} turns){s}; faulted cart {s}{s}\n", .{
        indent,
        c.name,
        c.bank,
        c.cell,
        rep.sprite,
        if (v.slot == 0) (v.first_diff orelse v.compared) else v.compared,
        rep.gb[0].len,
        states(rep.gb[0]),
        turns(rep.gb[0]),
        if (v.matched()) "" else if (v.slot == 0) " -- DIFFER" else " -- but a child it made DIFFERS",
        if (rep.fault.?.caught()) "differs" else "STILL AGREES",
        if (rep.unhandled_ai == c.ai) " -- the AI was never run" else "",
    });
    if (c.behaviour) |b| {
        try out.print("{s}  {s} broken: {s}\n", .{ indent, b.label, if (rep.behaviour_caught == true) "differs" else "STILL AGREES" });
    }
    if (c.by_number) {
        try out.print("{s}  the record: {s} the screen and {s} back\n", .{
            indent,
            if (leftAndCameBack(rep.gb[0])) "left" else "NEVER LEFT",
            if (leftAndCameBack(rep.gb[0])) "came" else "did not come",
        });
    }
    for (1..sample_slots) |slot| {
        if (!childOfSlot0(rep.gb, slot, c.child_flag)) continue;
        try out.print("{s}  and the child it made in slot {d}: {d} passes, {d} states\n", .{ indent, slot, rep.gb[slot].len, states(rep.gb[slot]) });
    }
    if (rep.camera_diff != 0) {
        try out.print("{s}  the camera: differs on {d} of {d} frames -- not the AI's fault\n", .{ indent, rep.camera_diff, rep.gb_cam.len });
    }
    // What a kill case is for, said in the case's own line rather than left to
    // "agree": each global that moved, and where it ended.
    var moved = false;
    for (rep.gb_globals) |g| moved = moved or g.len > 1;
    if (moved) {
        try out.print("{s}  the Metroid globals on the Game Boy:", .{indent});
        for (rep.gb_globals, globals) |g, gl| {
            if (g.len <= 1) continue;
            try out.print(" {s} {d} step(s) to ${X:0>2};", .{ gl.sym["Var".len..], g.len - 1, g[g.len - 1] });
        }
        try out.print("\n", .{});
    }
    if (rep.global_diff) |d| {
        const g = rep.gb_globals[d.global];
        const k = rep.cart_globals[d.global];
        try out.print("{s}  the Metroid globals DIFFER: {s} (${X:0>4}) at entry {d}\n{s}    gb:  ", .{ indent, globals[d.global].sym, globals[d.global].gb, d.at, indent });
        for (g[d.at -| 4..@min(g.len, d.at + 4)]) |b| try out.print("{X:0>2} ", .{b});
        try out.print("\n{s}    cart:", .{indent});
        for (k[d.at -| 4..@min(k.len, d.at + 4)]) |b| try out.print(" {X:0>2}", .{b});
        try out.print("\n", .{});
    }
    if (rep.world_diff != 0) {
        try out.print("{s}  the room: {d} tile(s) in view differ between the two maps at the seed -- not the AI's fault\n", .{ indent, rep.world_diff });
    }
    if (rep.end_diff != 0) {
        try out.print("{s}  the map after the last tick: {d} tile(s) in view differ\n", .{ indent, rep.end_diff });
    }
    if (v.first_diff) |d| {
        const lo = d -| 3;
        const g = rep.gb[v.slot];
        const k = rep.cart[v.slot];
        const hi = @min(@min(g.len, k.len), d + 4);
        try out.print("{s}  slot {d}, pass  gb: st  y  x spr at gv df ct sa fl   cart: st  y  x spr at gv df ct sa fl\n", .{ indent, v.slot });
        for (lo..hi) |i| {
            try out.print("{s}  {d:>13}      ", .{ indent, i });
            for (g[i]) |b| try out.print("{X:0>2} ", .{b});
            try out.print("        ", .{});
            for (k[i]) |b| try out.print("{X:0>2} ", .{b});
            try out.print("{s}\n", .{if (i == d) " <-" else ""});
        }
    }
}

/// Every AI James's recording dispatches through Alpha 2's death, from
/// `zig build gbtrace -- ais 73400` on 2026-09-13. See `docs/slice.md`. Kept
/// as the slice's record; the gate's census is now the ROM's, `roster.census`,
/// and the test below holds this one inside it.
pub const recorded_census = [_]u16{ 0x4DD3, 0x5542, 0x57DE, 0x58DE, 0x5ABF, 0x5CE0, 0x5E0B, 0x5F67, 0x61DB, 0x62B4, 0x6A14, 0x6BB2, 0x6C44 };
/// Every AI the 100% recording dispatches, all 25 segments unioned, from
/// `zig build gbtrace -- <segment> ais` on 2026-09-28 (1.0 Step 24b; see
/// `docs/phase1.md`). All 42 of the ROM's. As first written it left out `blobThrower`
/// (02:$4EA1), recorded as never dispatched; 1.0 Step 12 re-ran part 07 and it is
/// dispatched there 642 times from frame 100 in `$9:$1B` -- the omission was the
/// list's, not the run's. It found the census's one miss, Arachnus's fireball, now a
/// `roster.children`.
pub const recorded_census_100 = [_]u16{
    0x4DD3, 0x4EA1, 0x5109, 0x52DF, 0x536F, 0x54A1, 0x5542, 0x5651, 0x57DE, 0x58DE, 0x59C7, 0x5ABF,
    0x5AE2, 0x5BD4, 0x5C36, 0x5CE0, 0x5E0B, 0x5F67, 0x60AB, 0x60F8, 0x6145, 0x61DB, 0x62B4,
    0x638C, 0x6540, 0x65D5, 0x6622, 0x66F3, 0x6746, 0x6841, 0x68A0, 0x68FC, 0x695F, 0x6A14,
    0x6B83, 0x6BB2, 0x6C44, 0x6F60, 0x7276, 0x7631, 0x7A4F, 0x7BE5,
};
/// Census AIs not yet ported: every AI a spawn record anywhere in the ROM
/// reaches that `AiTable` does not carry. 1.0 Step 1 set it from
/// `roster.census`. **This list only shrinks**: the test below fails if an AI
/// is both here and in `AiTable`, so porting one means deleting it. The two
/// children, `roster.children`, are not here: they go with their parents.
/// Empty since 1.0 Step 21, the baby.
pub const pending = [_]u16{};
/// Ported and graded by another rung: the item orb by `snes boot`'s pickup
/// phase; the small bug and the Senjoo by the segment (Step 10); `enAI_NULL`
/// is a bare `ret`.
pub const graded_elsewhere = [_]u16{ 0x4DD3, 0x5ABF, 0x5C36, 0x5651 };

fn has(list: []const u16, v: u16) bool {
    return std.mem.indexOfScalar(u16, list, v) != null;
}

/// The AI addresses the assembled `AiTable` and `AiTableFar` carry.
pub fn tableAis(allocator: std.mem.Allocator) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(allocator);
    for (ai_tables) |t| {
        const table = inject.symbolOffset(t[0]) orelse return Error.MissingSymbol;
        const end = inject.symbolOffset(t[1]) orelse return Error.MissingSymbol;
        var at = table;
        while (at < end) : (at += 4) {
            try out.append(allocator, @as(u16, inject.image[at]) | (@as(u16, inject.image[at + 1]) << 8));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// The fewest distinct entries a case's Game Boy history may have. An AI that
/// barely moves in its room grades nothing, the argument `chooseStart` makes
/// about a Samus that barely moves.
pub const min_passes: usize = 20;

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;
const testrom = @import("testrom");

test "a history collapses its runs and keeps its order" {
    var a: Sample = @splat(0xFF);
    var b: Sample = @splat(0xFF);
    a[0] = 0;
    b[0] = 0;
    b[7] = 1;
    const got = try passes(testing.allocator, &.{ a, a, b, b, a }, 0);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 3), got.len);
    const sa: SlotSample = a[0..sample_fields.len].*;
    const sb: SlotSample = b[0..sample_fields.len].*;
    try testing.expect(std.mem.eql(u8, &got[2], &sa));
    try testing.expect(compare(&.{ sa, sb }, &.{ sa, sa }).first_diff.? == 1);
    try testing.expect(compare(&.{ sa, sb }, &.{ sa, sb, sa }).matched());
}

test "every case's cell carries a record whose header names the case's AI" {
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    for (cases ++ reload_cases) |c| {
        const rec = try recordFor(testing.allocator, rom, c);
        try testing.expectEqual(c.ai, aiFor(rom, rec.sprite));
        // And the seed carries the same word, where `EnemyCommonAI` reads it.
        const s = seedSlot(rom, rec, 0, 0);
        try testing.expectEqual(c.ai, @as(u16, s[0x1E]) | (@as(u16, s[0x1F]) << 8));
    }
}

test "every reload case's record is in the half of the flag array its comment claims" {
    // Step 19. The two Metroids are the point of the rung and their numbers have
    // to be in the *saved* half -- $40 and up, the half a room load does not
    // refill -- and the control's has to be below it, or the control controls
    // for nothing. The ROM's Metroid records are numbers $40 to $56; this reads
    // the number out of the record rather than trusting that.
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    var saved: usize = 0;
    var unsaved: usize = 0;
    for (reload_cases) |c| {
        const rec = try recordFor(testing.allocator, rom, c);
        const metroid = c.ai == 0x6BB2 or c.ai == 0x6C44;
        if (metroid) {
            try testing.expect(rec.number >= 0x40);
            saved += 1;
        } else {
            try testing.expect(rec.number < 0x40);
            unsaved += 1;
        }
    }
    try testing.expect(saved != 0 and unsaved != 0);
}

test "every reload case drives the camera and follows its record" {
    // The two levers the rung cannot do without: a case with no sweep never
    // takes the enemy off the screen, and a case that graded slot 0 would end up
    // grading whichever neighbour the walk dropped into it. See `Case.sweep`,
    // `Case.by_number` and `Case.freeze`.
    for (reload_cases) |c| {
        try testing.expect(c.sweep.len != 0);
        try testing.expect(c.by_number);
        try testing.expect(c.freeze);
    }
}

test "a record that leaves and comes back is told from one that does not" {
    const live: SlotSample = @splat(0x11);
    const gone: SlotSample = @splat(0xFF);
    try testing.expect(leftAndCameBack(&.{ live, gone, live }));
    try testing.expect(!leftAndCameBack(&.{ live, live }));
    try testing.expect(!leftAndCameBack(&.{ live, gone }));
    try testing.expect(!leftAndCameBack(&.{ gone, live }));
    try testing.expect(!leftAndCameBack(&.{}));
}

test "every case's AI is one the engine's table can be faulted on" {
    for (cases ++ reload_cases) |c| {
        const cart = try testing.allocator.dupe(u8, inject.image);
        defer testing.allocator.free(cart);
        try blankAiRow(cart, c.ai);
    }
}

test "every AI the ROM's spawn records reach is ported or pending -- and a ported one is graded" {
    // Step 12f's standing rung, widened by 1.0 Step 1 from the recording to the
    // ROM. An AI that nobody ported is a build failure here rather than an
    // enemy that quietly sits still, which is what the 2026-09-09 playtest
    // found.
    const rom = try testrom.load(testing.allocator) orelse return error.SkipZigTest;
    defer testing.allocator.free(rom);
    const census = try roster.census(testing.allocator, rom);
    defer testing.allocator.free(census);
    const in_table = try tableAis(testing.allocator);
    defer testing.allocator.free(in_table);
    var bad: usize = 0;
    for (census) |c| {
        const ai = c.ai;
        const ported = has(in_table, ai);
        if (ported == has(&pending, ai)) {
            std.debug.print("02:{X:0>4} {s}: {s}\n", .{ ai, roster.nameOf(ai), if (ported) "ported and still pending" else "neither ported nor pending" });
            bad += 1;
        }
        if (!ported or has(&graded_elsewhere, ai)) continue;
        for (cases) |k| {
            if (k.ai == ai) break;
        } else {
            std.debug.print("02:{X:0>4} {s}: ported with no enemy oracle case\n", .{ ai, roster.nameOf(ai) });
            bad += 1;
        }
    }
    // A pending AI the census does not reach is a typo, not a backlog.
    for (pending) |ai| {
        for (census) |c| {
            if (c.ai == ai) break;
        } else {
            std.debug.print("02:{X:0>4}: pending but no spawn record reaches it\n", .{ai});
            bad += 1;
        }
    }
    // The recordings' censuses are inside the ROM's, children included: an AI
    // a recording dispatches that neither reaches is one the census missed.
    for (recorded_census ++ recorded_census_100) |ai| {
        const child = for (roster.children) |ch| {
            if (ch.ai == ai) break true;
        } else false;
        if (child) continue;
        for (census) |c| {
            if (c.ai == ai) break;
        } else {
            std.debug.print("02:{X:0>4}: a recording dispatches it and the census misses it\n", .{ai});
            bad += 1;
        }
    }
    // A child is ported exactly when its parent is.
    for (roster.children) |ch| {
        if (has(in_table, ch.ai) != has(in_table, ch.parent)) {
            std.debug.print("02:{X:0>4} {s}: ported apart from its parent\n", .{ ch.ai, ch.name });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
