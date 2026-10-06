const std = @import("std");

/// The user's ROM, resolved at configure time. `mise.toml` exports `M2_ROM`
/// when it finds one; an explicit `-Drom=` wins over that. Empty means absent:
/// `test` then skips the ROM tests, and `test-rom`, `verify` and `verify-full`
/// fail (`rom_check`), so no gate can report green without the ROM.
fn romPath(b: *std.Build) []const u8 {
    if (b.option([]const u8, "rom", "Path to your Metroid II (World) Game Boy ROM")) |p| {
        if (p.len != 0) return p;
    }
    return b.graph.environ_map.get("M2_ROM") orelse "";
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rom_path = romPath(b);

    // Mesen2, for the headless boot test. Empty means "not installed", which
    // `verify` reports as a notice rather than treating as a pass.
    const mesen_path = b.option([]const u8, "mesen", "Path to the Mesen2 binary") orelse
        (b.graph.environ_map.get("MESEN") orelse "");

    // `locate.zig`'s two write surveys dump a table of which routine wrote
    // which address. They are how the module's claims were *found*, so they
    // stay reachable -- but anything a test binary writes to stderr makes
    // `zig build test` print a `failed command:` line under `--listen=-` even
    // when every test passed, and on 2026-09-02 three real failures were read
    // as pre-existing noise because of it. Off unless asked for:
    // `zig build test -Dsurvey` or `M2_SURVEY=1 zig build test`.
    const survey = b.option(bool, "survey", "Print locate.zig's write surveys (noisy; off by default)") orelse
        (b.graph.environ_map.get("M2_SURVEY") != null);

    const options = b.addOptions();
    options.addOption([]const u8, "rom_path", rom_path);
    options.addOption([]const u8, "mesen_path", mesen_path);
    options.addOption(bool, "survey", survey);

    // SameBoy is vendored and `vendor/` is not tracked, so a machine can have
    // the ROM and not the reference the audio A/B and the gate's `audio level`
    // rung render the Game Boy with. Everything that links it asks this first.
    const sameboy_root = "vendor/sameboy";
    const have_sameboy = blk: {
        b.build_root.handle.access(b.graph.io, sameboy_root ++ "/Core/apu.c", .{}) catch break :blk false;
        break :blk true;
    };
    options.addOption(bool, "have_sameboy", have_sameboy);

    // ---- Modules -----------------------------------------------------------
    const rom_mod = b.createModule(.{
        .root_source_file = b.path("src/rom.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The one way a test reads the user's ROM (`src/testrom.zig`).
    const testrom_mod = b.createModule(.{
        .root_source_file = b.path("src/testrom.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Its own options, not `build_options`: `addOptions` wraps the generated
    // file in a new module per call, and one compilation cannot hold the same
    // file in two modules.
    const testrom_options = b.addOptions();
    testrom_options.addOption([]const u8, "rom_path", rom_path);
    testrom_mod.addOptions("testrom_options", testrom_options);
    const offsets_mod = b.createModule(.{
        .root_source_file = b.path("src/offsets.zig"),
        .target = target,
        .optimize = optimize,
    });
    const policy_mod = b.createModule(.{
        .root_source_file = b.path("src/policy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pin_mod = b.createModule(.{
        .root_source_file = b.path("src/pin.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The repository's pin and its history, for the test that the two agree
    // (release Step 9): it needs no ROM, so CI runs it.
    pin_mod.addAnonymousImport("pins_cart", .{ .root_source_file = b.path("pins/cart.txt") });
    pin_mod.addAnonymousImport("pins_history", .{ .root_source_file = b.path("pins/history.md") });
    const gitblob_mod = b.createModule(.{
        .root_source_file = b.path("src/gitblob.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gfx_mod = b.createModule(.{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    // tileset.zig and extract.zig re-derive facts from the ROM in their tests,
    // so they need the configured path and skip when it is empty.
    const tileset_mod = b.createModule(.{
        .root_source_file = b.path("src/tileset.zig"),
        .target = target,
        .optimize = optimize,
    });
    tileset_mod.addOptions("build_options", options);
    tileset_mod.addImport("testrom", testrom_mod);
    const physics_mod = b.createModule(.{
        .root_source_file = b.path("src/physics.zig"),
        .target = target,
        .optimize = optimize,
    });
    // items.zig reads the retail ROM in two of its tests - the sixteen names,
    // and the byte after the block - so it needs the configured path and the
    // working directory, which is why it joins the second list below.
    const items_mod = b.createModule(.{
        .root_source_file = b.path("src/items.zig"),
        .target = target,
        .optimize = optimize,
    });
    items_mod.addOptions("build_options", options);
    items_mod.addImport("testrom", testrom_mod);
    // blocks.zig reads the retail ROM in every one of its tests: it exists to
    // read the block mechanism's constants out of the opcodes that carry them.
    // Like sprites.zig it must NOT get the engine -- the check that ties these
    // numbers to the engine's own lives in correspond.zig, which already has
    // the symbol file.
    const blocks_mod = b.createModule(.{
        .root_source_file = b.path("src/blocks.zig"),
        .target = target,
        .optimize = optimize,
    });
    blocks_mod.addOptions("build_options", options);
    blocks_mod.addImport("testrom", testrom_mod);

    // sprites.zig reads the ROM in the tests that check the three tables Step
    // 11 pinned. It must NOT get the engine: half a dozen modules import it,
    // and an engine embed here would pull `engine.bin` into every one of them.
    // The check that ties the engine's constants to those tables lives in
    // correspond.zig, which has the symbol file already.
    const sprites_mod = b.createModule(.{
        .root_source_file = b.path("src/sprites.zig"),
        .target = target,
        .optimize = optimize,
    });
    sprites_mod.addOptions("build_options", options);
    sprites_mod.addImport("testrom", testrom_mod);
    const map_mod = b.createModule(.{
        .root_source_file = b.path("src/map.zig"),
        .target = target,
        .optimize = optimize,
    });
    map_mod.addOptions("build_options", options);
    map_mod.addImport("testrom", testrom_mod);
    const door_mod = b.createModule(.{
        .root_source_file = b.path("src/door.zig"),
        .target = target,
        .optimize = optimize,
    });
    const entity_mod = b.createModule(.{
        .root_source_file = b.path("src/entity.zig"),
        .target = target,
        .optimize = optimize,
    });
    entity_mod.addOptions("build_options", options);
    entity_mod.addImport("testrom", testrom_mod);
    const extract_mod = b.createModule(.{
        .root_source_file = b.path("src/extract.zig"),
        .target = target,
        .optimize = optimize,
    });
    extract_mod.addOptions("build_options", options);
    extract_mod.addImport("testrom", testrom_mod);
    const roundtrip_mod = b.createModule(.{
        .root_source_file = b.path("src/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    roundtrip_mod.addOptions("build_options", options);
    roundtrip_mod.addImport("testrom", testrom_mod);
    const png_mod = b.createModule(.{
        .root_source_file = b.path("src/png.zig"),
        .target = target,
        .optimize = optimize,
    });
    png_module = png_mod;
    const screens_mod = b.createModule(.{
        .root_source_file = b.path("src/screens.zig"),
        .target = target,
        .optimize = optimize,
    });
    screens_mod.addOptions("build_options", options);
    screens_mod.addImport("testrom", testrom_mod);
    // The SNES-side converters. They read the extraction modules, so they are
    // created after them; `target.zig` has no dependencies at all.
    const snes_files = [_][]const u8{
        "src/snes_target.zig", "src/snes_chr.zig", "src/snes_convert.zig",
        "src/snes_layout.zig", "src/snes_screen.zig", "src/snes_render.zig",
        "src/snes_inject.zig", "src/inspect.zig", "src/title_super.zig",
        "src/gfx_info.zig",
    };
    var snes_mods: [snes_files.len]*std.Build.Module = undefined;
    for (snes_files, 0..) |f, i| {
        snes_mods[i] = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
        });
        snes_mods[i].addOptions("build_options", options);
        snes_mods[i].addImport("testrom", testrom_mod);
        // `inspect.zig` writes PNGs; the others ignore this import.
        snes_mods[i].addImport("png", png_mod);
        // The assembled engine, embedded rather than read at run time: the
        // shipped builder is one file. `tools/build-engine.sh` regenerates
        // both, and `verify` checks the committed pair still matches the
        // source when an assembler is present.
        addEngine(b, snes_mods[i]);
    }

    const coverage_mod = b.createModule(.{
        .root_source_file = b.path("src/coverage.zig"),
        .target = target,
        .optimize = optimize,
    });
    coverage_mod.addOptions("build_options", options);
    coverage_mod.addImport("testrom", testrom_mod);

    // Per-routine unit tests against the retail ROM. ReleaseFast for the same
    // reason as the emulator: they run tens of thousands of emulated
    // instructions and report a value, not a stack trace.
    const routines_mod = b.createModule(.{
        .root_source_file = b.path("src/routines.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    routines_mod.addOptions("build_options", options);
    routines_mod.addImport("testrom", testrom_mod);
    routines_mod.addImport("png", png_mod);

    // The address correspondence map. It reads the engine's symbol file, so
    // it needs the same `addEngine` the SNES modules get.
    const correspond_mod = b.createModule(.{
        .root_source_file = b.path("src/correspond.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    correspond_mod.addOptions("build_options", options);
    correspond_mod.addImport("testrom", testrom_mod);
    correspond_mod.addImport("png", png_mod);
    addEngine(b, correspond_mod);

    // The oracle: the hand-authored segment and the comparator.
    const oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/oracle.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    oracle_mod.addOptions("build_options", options);
    oracle_mod.addImport("testrom", testrom_mod);
    oracle_mod.addImport("png", png_mod);
    addEngine(b, oracle_mod);

    // 1.0 Step 1: the backlog read out of the ROM -- the AI census, the
    // Metroid roster, the warp page's destinations and door-op coverage.
    const roster_mod = b.createModule(.{
        .root_source_file = b.path("src/roster.zig"),
        .target = target,
        .optimize = optimize,
    });
    roster_mod.addOptions("build_options", options);
    roster_mod.addImport("testrom", testrom_mod);

    // 1.0 Step 4: the debug menu's METROIDS and FLAGS lists, from the roster.
    const debug_tables_mod = b.createModule(.{
        .root_source_file = b.path("src/debug_tables.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_tables_mod.addOptions("build_options", options);
    debug_tables_mod.addImport("testrom", testrom_mod);
    const crawl_mod = b.createModule(.{
        .root_source_file = b.path("src/crawl.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    crawl_mod.addOptions("build_options", options);
    crawl_mod.addImport("testrom", testrom_mod);
    const warp_mod = b.createModule(.{
        .root_source_file = b.path("src/warp.zig"),
        .target = target,
        .optimize = optimize,
    });
    warp_mod.addOptions("build_options", options);
    warp_mod.addImport("testrom", testrom_mod);

    // Step 12f's enemy oracle: an AI graded against the Game Boy running it.
    const enemy_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/enemy_oracle.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    enemy_oracle_mod.addOptions("build_options", options);
    enemy_oracle_mod.addImport("testrom", testrom_mod);
    enemy_oracle_mod.addImport("png", png_mod);
    addEngine(b, enemy_oracle_mod);

    // 1.0 Step 19a's Queen oracle: her fight graded against our Game Boy's.
    const queen_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/queen_oracle.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    queen_oracle_mod.addOptions("build_options", options);
    queen_oracle_mod.addImport("testrom", testrom_mod);
    queen_oracle_mod.addImport("png", png_mod);
    addEngine(b, queen_oracle_mod);

    // Step 13b's HUD oracle: the status bar graded against the Game Boy drawing it.
    const hud_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/hud_oracle.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    hud_oracle_mod.addOptions("build_options", options);
    hud_oracle_mod.addImport("testrom", testrom_mod);
    hud_oracle_mod.addImport("png", png_mod);
    addEngine(b, hud_oracle_mod);

    // Step 24h's title oracle: the file select on the Game Boy, frame by frame.
    const title_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/title_oracle.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    title_oracle_mod.addOptions("build_options", options);
    title_oracle_mod.addImport("testrom", testrom_mod);
    title_oracle_mod.addImport("png", png_mod);
    addEngine(b, title_oracle_mod);

    // 1.0 Step 2a's pause oracle: `tryPausing` and mode $08 on the Game Boy.
    const pause_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/pause_oracle.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    pause_oracle_mod.addOptions("build_options", options);
    pause_oracle_mod.addImport("testrom", testrom_mod);
    pause_oracle_mod.addImport("png", png_mod);
    addEngine(b, pause_oracle_mod);

    // 1.0 Step 3's scenarios: the debug cart set up through its menu.
    const scenario_mod = b.createModule(.{
        .root_source_file = b.path("src/scenario.zig"),
        .target = target,
        .optimize = optimize,
    });
    scenario_mod.addOptions("build_options", options);
    scenario_mod.addImport("testrom", testrom_mod);
    scenario_mod.addImport("png", png_mod);
    addEngine(b, scenario_mod);

    // 1.0 Step 5c: the WARP page graded against the Game Boy running each chain.
    const warp_grade_mod = b.createModule(.{
        .root_source_file = b.path("src/warp_grade.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    warp_grade_mod.addOptions("build_options", options);
    warp_grade_mod.addImport("testrom", testrom_mod);
    warp_grade_mod.addImport("png", png_mod);
    addEngine(b, warp_grade_mod);

    // The residue audit: what the opening leaves behind, and whether we read it.
    const residue_mod = b.createModule(.{
        .root_source_file = b.path("src/residue.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    residue_mod.addOptions("build_options", options);
    residue_mod.addImport("testrom", testrom_mod);
    residue_mod.addImport("png", png_mod);
    addEngine(b, residue_mod);

    // The table-driven dispatch survey (F4).
    const dispatch_mod = b.createModule(.{
        .root_source_file = b.path("src/dispatch.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    dispatch_mod.addOptions("build_options", options);
    dispatch_mod.addImport("testrom", testrom_mod);
    dispatch_mod.addImport("png", png_mod);

    // The Game Boy cost of `handleAudio` (metroid2-audio Step 2). ReleaseFast:
    // its test emulates a hundred calls of the sound engine.
    const audiocost_mod = b.createModule(.{
        .root_source_file = b.path("src/audiocost.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audiocost_mod.addOptions("build_options", options);
    audiocost_mod.addImport("testrom", testrom_mod);
    audiocost_mod.addImport("png", png_mod);
    addEngine(b, dispatch_mod);

    // The synced GB APU shim package, checked against its own MANIFEST. Needs
    // neither the ROM nor an assembler, so it is an ordinary unit test as well
    // as a rung of the gate.
    const audio_shim_mod = b.createModule(.{
        .root_source_file = b.path("src/audio_shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Bank 4's sound data (metroid2-audio Step 5): typed readers, re-encoders
    // and the build-time pointer relocation into ARAM.
    const audio_data_mod = b.createModule(.{
        .root_source_file = b.path("src/audio_data.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_data_mod.addOptions("build_options", options);
    audio_data_mod.addImport("testrom", testrom_mod);

    // Where all of that lands in the SPC700's 64 KiB. The region bounds come
    // from the synced package's generated `shimpkg.zig` rather than from a copy
    // of them here, so a shim that moved a region moves this layout with it.
    const aram_layout_mod = b.createModule(.{
        .root_source_file = b.path("src/aram_layout.zig"),
        .target = target,
        .optimize = optimize,
    });
    aram_layout_mod.addOptions("build_options", options);
    aram_layout_mod.addImport("testrom", testrom_mod);
    addShimpkg(b, aram_layout_mod);

    // The one file both sides of the audio comparison are driven from, and the
    // slot numbers it shares with the engine's own source.
    const audio_req_mod = b.createModule(.{
        .root_source_file = b.path("src/audio_req.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_req_mod.addOptions("build_options", options);
    audio_req_mod.addImport("testrom", testrom_mod);

    // The comparison itself: both engines, one script, the first divergent tick.
    const audiocmp_mod = b.createModule(.{
        .root_source_file = b.path("src/audiocmp.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audiocmp_mod.addOptions("build_options", options);
    audiocmp_mod.addImport("testrom", testrom_mod);

    // What the A/B asks for and how it judges what came out. The half that
    // links SameBoy is `src/audioab_render.zig`, which is built only by the
    // `audioab` step, so this much is tested wherever the gate runs.
    const audioab_mod = b.createModule(.{
        .root_source_file = b.path("src/audioab.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audioab_mod.addOptions("build_options", options);
    audioab_mod.addImport("testrom", testrom_mod);

    // The level check's set and grade (metroid2-0b Step 24f). Its renders are
    // `src/audio_level_run.zig`, which links SameBoy; this half does not.
    const audio_level_mod = b.createModule(.{
        .root_source_file = b.path("src/audio_level.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_level_mod.addOptions("build_options", options);
    audio_level_mod.addImport("testrom", testrom_mod);

    // The container both renders land in.
    const wav_mod = b.createModule(.{
        .root_source_file = b.path("src/wav.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The bytes that go at those addresses: the image the cart uploads at boot,
    // and the one `spcrun` runs offline when `audiocmp` grades the engine.
    const aram_image_mod = b.createModule(.{
        .root_source_file = b.path("src/aram_image.zig"),
        .target = target,
        .optimize = optimize,
    });
    aram_image_mod.addOptions("build_options", options);
    aram_image_mod.addImport("testrom", testrom_mod);
    addShimpkg(b, aram_image_mod);

    // What the engine costs the SPC700, offline: the same script with the
    // engine and with a null engine, and the idle rate between them.
    const audioload_mod = b.createModule(.{
        .root_source_file = b.path("src/audioload.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audioload_mod.addOptions("build_options", options);
    audioload_mod.addImport("testrom", testrom_mod);
    addShimpkg(b, audioload_mod);

    // How long a door transition takes, and the rule the number comes out of.
    const transition_mod = b.createModule(.{
        .root_source_file = b.path("src/transition.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    transition_mod.addOptions("build_options", options);
    transition_mod.addImport("testrom", testrom_mod);
    transition_mod.addImport("png", png_mod);
    // The engine image and source, because the frame table this module computes
    // is also assembled into the cart and the two are checked against each
    // other rather than kept in step by hand.
    addEngine(b, transition_mod);

    // Durations: the stretches the port cannot be graded frame-exactly on.
    const duration_mod = b.createModule(.{
        .root_source_file = b.path("src/duration.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    duration_mod.addOptions("build_options", options);
    duration_mod.addImport("testrom", testrom_mod);
    duration_mod.addImport("png", png_mod);
    addEngine(b, duration_mod);

    // The save-RAM channel the oracle's one-byte verdict does not have room for.
    const trace_mod = b.createModule(.{
        .root_source_file = b.path("src/snes_trace.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    trace_mod.addOptions("build_options", options);
    trace_mod.addImport("testrom", testrom_mod);
    trace_mod.addImport("png", png_mod);
    addEngine(b, trace_mod);
    const audio_parity_mod = b.createModule(.{
        .root_source_file = b.path("src/audio_parity.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audio_parity_mod.addOptions("build_options", options);
    audio_parity_mod.addImport("testrom", testrom_mod);
    audio_parity_mod.addImport("png", png_mod);
    addEngine(b, audio_parity_mod);
    const audio_sites_mod = b.createModule(.{
        .root_source_file = b.path("src/audio_sites.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_sites_mod.addOptions("build_options", options);
    audio_sites_mod.addImport("testrom", testrom_mod);
    audio_sites_mod.addImport("png", png_mod);

    // The save record's layout, re-derived from the ROM.
    const save_mod = b.createModule(.{
        .root_source_file = b.path("src/save.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    save_mod.addOptions("build_options", options);
    save_mod.addImport("testrom", testrom_mod);
    save_mod.addImport("png", png_mod);

    // The TAS driver. ReleaseFast for the same reason the ledger is: its
    // tests parse a 325 KiB movie and replay a prefix of it.
    const tas_mod = b.createModule(.{
        .root_source_file = b.path("src/tas.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    tas_mod.addOptions("build_options", options);
    tas_mod.addImport("testrom", testrom_mod);
    tas_mod.addImport("png", png_mod);

    // The Game Boy reference trace, taken off Mesen2 rather than replayed.
    // ReleaseFast for the same reason `tas_mod` is: it parses a megabyte of
    // movie and hashes work RAM.
    const gb_trace_mod = b.createModule(.{
        .root_source_file = b.path("src/gb_trace.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    gb_trace_mod.addOptions("build_options", options);
    gb_trace_mod.addImport("testrom", testrom_mod);
    gb_trace_mod.addImport("png", png_mod);

    // Routine ownership, observed over a published run. ReleaseFast for the
    // same reason `tas_mod` is: its tests replay thousands of frames.
    const locate_mod = b.createModule(.{
        .root_source_file = b.path("src/locate.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    locate_mod.addOptions("build_options", options);
    locate_mod.addImport("testrom", testrom_mod);
    locate_mod.addImport("png", png_mod);

    // Samus's death on the Game Boy, measured: the lengths the cart's death is
    // graded against.
    const death_mod = b.createModule(.{
        .root_source_file = b.path("src/death.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    death_mod.addOptions("build_options", options);
    death_mod.addImport("testrom", testrom_mod);
    death_mod.addImport("png", png_mod);

    // The ending on the Game Boy, measured (1.0 Step 22): the lengths the
    // cart's credits are graded against.
    const credits_mod = b.createModule(.{
        .root_source_file = b.path("src/credits.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    credits_mod.addOptions("build_options", options);
    credits_mod.addImport("testrom", testrom_mod);
    credits_mod.addImport("png", png_mod);

    // The room test harness. ReleaseFast: its tests boot the game and warp
    // around it, which is minutes of emulation at -ODebug.
    const room_mod = b.createModule(.{
        .root_source_file = b.path("src/room.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    room_mod.addOptions("build_options", options);
    room_mod.addImport("testrom", testrom_mod);
    room_mod.addImport("png", png_mod);

    // The logic ledger. ReleaseFast even in a debug build, for the same reason
    // the emulator is: its unit test disassembles all six code banks to a
    // fixpoint, and at -ODebug that is gate time for no diagnostic benefit.
    const ledger_mod = b.createModule(.{
        .root_source_file = b.path("src/ledger.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    ledger_mod.addOptions("build_options", options);
    ledger_mod.addImport("testrom", testrom_mod);
    ledger_mod.addImport("png", png_mod);

    // ---- The builder itself (release Step 6) ---------------------------------
    //
    // The binary a player runs, built by `builderExe` (which says why its
    // options are its own). The host's is the one installed, run by the gate
    // and graded by `pin-check`; `zig build release` builds the same thing
    // for every release target.
    const builder_opts = BuilderOptions.init(b);
    // Stripped when `-Dtarget=` names a target, so `pin-check -Dtarget=…`
    // grades the binary `release` ships; the host's dev build keeps its debug
    // info for stack traces.
    const exe = builderExe(b, builder_opts, target, builder_optimize, !target.query.isNative());
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the builder against a ROM").dependOn(&run_cmd.step);

    // `zig build release`: the binary for every release target, into
    // zig-out/release/<target>/. Baseline CPUs, so it runs on any machine of
    // the architecture. Stripped: Zig 0.16 records debug info's source and
    // lib paths absolute, with no prefix map, and a shipped binary must not
    // name the build host (`pathscan`). No `.pdb`: the archive ships the
    // binary alone.
    //
    // Then `pathscan` over every one: no build-host path may ship. Its own
    // prefixes are this build's root, Zig lib dir and global cache.
    const pathscan_mod = b.createModule(.{
        .root_source_file = b.path("src/pathscan.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const pathscan_run = b.addRunArtifact(b.addExecutable(.{ .name = "pathscan", .root_module = pathscan_mod }));
    pathscan_run.has_side_effects = true;
    for ([_]?[]const u8{ b.build_root.path, b.graph.zig_lib_directory.path, b.graph.global_cache_root.path }) |p|
        if (p) |path| pathscan_run.addArgs(&.{ "--prefix", path });
    const release_step = b.step("release", "Cross-compile m2snes for every release target into zig-out/release/, and scan them for host paths");
    for (release_targets) |t| {
        const rt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = t }) catch unreachable);
        const release_exe = builderExe(b, builder_opts, rt, builder_optimize, true);
        const install = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{t}) } },
            .pdb_dir = .disabled,
        });
        release_step.dependOn(&install.step);
        pathscan_run.addArtifactArg(release_exe);
    }
    release_step.dependOn(&pathscan_run.step);

    // ---- The Game Boy emulator ---------------------------------------------
    //
    // Built at ReleaseFast even in a debug build. These tests run blargg's
    // suites and 1200 frames of the retail ROM; at -ODebug that is ten seconds
    // of gate time for no diagnostic benefit, since what they report is a
    // string from the test ROM rather than a Zig stack trace.
    const gb_files = [_][]const u8{
        "src/gb/cpu.zig",   "src/gb/cart.zig", "src/gb/timer.zig",
        "src/gb/lcd.zig",
        "src/gb/ppu.zig",   "src/gb/apu.zig",  "src/gb/bus.zig",
        "src/gb/system.zig", "src/gb/blargg.zig", "src/gb/trace.zig",
        "src/gb/sameboy.zig", "src/gb/probe.zig", "src/gb/disasm.zig",
        "src/gb/harness.zig",
    };
    var gb_mods: [gb_files.len]*std.Build.Module = undefined;
    for (gb_files, 0..) |f, i| {
        gb_mods[i] = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = .ReleaseFast,
        });
        gb_mods[i].addOptions("build_options", options);
        gb_mods[i].addImport("testrom", testrom_mod);
        // The SameBoy comparison writes PNGs of any mismatch it finds.
        gb_mods[i].addImport("png", png_mod);
    }

    // ---- The door crawl (1.0 Step 5a) ---------------------------------------
    //
    // Our Game Boy walks every door; the warp table is built from what it
    // loaded. ReleaseFast because it emulates a few minutes of play, and
    // cached in build-out/ by ROM and crawler version: every step that
    // converts depends on this one, and after the first run it does nothing.
    const crawl_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/crawl_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    crawl_mod_exe.addOptions("build_options", options);
    crawl_mod_exe.addImport("testrom", testrom_mod);
    const crawl_exe = b.addExecutable(.{ .name = "crawl", .root_module = crawl_mod_exe });
    const crawl_run = b.addRunArtifact(crawl_exe);
    crawl_run.setCwd(b.path("."));
    crawl_run.has_side_effects = true;
    b.step("crawl", "Walk every door on the Game Boy and cache what each loads (the warp table's input)")
        .dependOn(&crawl_run.step);

    // ---- Unit tests --------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    {
        const t = b.addTest(.{ .root_module = death_mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        run.setCwd(b.path("."));
        b.step("test-death", "Run the death measurement's tests").dependOn(&run.step);
    }
    {
        addAudio(b, credits_mod);
        const t = b.addTest(.{ .root_module = credits_mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        run.setCwd(b.path("."));
        b.step("test-credits", "Run the credits measurement's tests").dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .root_module = title_oracle_mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        run.setCwd(b.path("."));
        b.step("test-title", "Run the title oracle's tests").dependOn(&run.step);
    }
    const test_filter = b.option([]const u8, "test-filter", "Run only the tests whose names contain this (test-pause, test-warp)");
    {
        const t = b.addTest(.{ .root_module = pause_oracle_mod, .filters = if (test_filter) |f| &.{f} else &.{} });
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        run.setCwd(b.path("."));
        b.step("test-pause", "Run the pause oracle's tests").dependOn(&run.step);
    }
    {
        const step = b.step("test-warp", "Run the warp table's and the warp grade's tests");
        for ([_]*std.Build.Module{ warp_mod, warp_grade_mod }) |mod| {
            const t = b.addTest(.{ .root_module = mod, .filters = if (test_filter) |f| &.{f} else &.{} });
            const run = b.addRunArtifact(t);
            run.step.dependOn(&crawl_run.step);
            run.setCwd(b.path("."));
            step.dependOn(&run.step);
        }
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pathscan_mod })).step);
    {
        // The ratchet in `testrom.zig` reads src/, which the test binary does
        // not depend on, so the run must not be cached.
        const t = b.addTest(.{ .root_module = testrom_mod });
        const run = b.addRunArtifact(t);
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }
    for ([_]*std.Build.Module{ rom_mod, policy_mod, pin_mod, gitblob_mod, offsets_mod, gfx_mod, tileset_mod, physics_mod, map_mod, door_mod, entity_mod, extract_mod, roundtrip_mod, coverage_mod, png_mod, screens_mod, wav_mod }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        test_step.dependOn(&run.step);
    }
    for ([_]*std.Build.Module{ audiocost_mod, audio_shim_mod, audio_data_mod, aram_layout_mod, aram_image_mod, audioload_mod, audio_req_mod, audiocmp_mod, audioab_mod, audio_level_mod, items_mod, sprites_mod, blocks_mod, ledger_mod, routines_mod, room_mod, death_mod, credits_mod, tas_mod, locate_mod, gb_trace_mod, save_mod, correspond_mod, oracle_mod, enemy_oracle_mod, queen_oracle_mod, hud_oracle_mod, title_oracle_mod, pause_oracle_mod, scenario_mod, residue_mod, duration_mod, transition_mod, dispatch_mod, trace_mod, audio_parity_mod, audio_sites_mod, roster_mod, debug_tables_mod, warp_mod, crawl_mod, warp_grade_mod }) |mod| {
        // Separate from the list above only because these need the working
        // directory set: both find the retail ROM by relative path.
        addAudio(b, mod);
        const t = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        run.setCwd(b.path("."));
        test_step.dependOn(&run.step);
    }
    for (snes_mods) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        run.setCwd(b.path("."));
        test_step.dependOn(&run.step);
    }
    for (gb_mods) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        // The blargg ROMs and the retail ROM are both found by relative path.
        const run = b.addRunArtifact(t);
        run.step.dependOn(&crawl_run.step);
        run.setCwd(b.path("."));
        test_step.dependOn(&run.step);
    }

    // ---- The gate ----------------------------------------------------------
    //
    // There is no CI, and there cannot be one with the ROM: it is not ours to
    // distribute. `verify` is the local stand-in, and every later step hangs
    // its gate here. It runs the unit tests, the tracked-file policy check and
    // the ROM-dependent rungs, and it fails without a ROM (`rom_check`),
    // because a gate that silently does nothing reports green and is worse
    // than no gate at all. `test` alone still runs without one, skipping the
    // ROM tests; `test-rom` is `test` with the ROM required.
    const rom_check: ?*std.Build.Step = if (rom_path.len == 0) &b.addFail(
        "no ROM: set M2_ROM (mise.toml) or pass -Drom=; see docs/setup.md",
    ).step else null;
    const test_rom_step = b.step("test-rom", "Run unit tests, failing if no ROM is configured");
    test_rom_step.dependOn(test_step);
    if (rom_check) |c| test_rom_step.dependOn(c);
    // ReleaseSafe, not the build's optimize mode: `verify` runs the extraction
    // twice, the round-trip over 190 KiB, and 1200 frames of emulation. Safety
    // checks stay on - a gate that can silently misbehave is worthless - but
    // there is no reason to pay Debug's price for them.
    const verify_mod = b.createModule(.{
        .root_source_file = b.path("src/verify.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    verify_mod.addOptions("build_options", options);
    verify_mod.addImport("testrom", testrom_mod);
    addShimpkg(b, verify_mod);
    addEngine(b, verify_mod);
    // The gate reports the SameBoy comparison's numbers, and that module writes
    // PNGs of any mismatch it finds.
    verify_mod.addImport("png", png_mod);
    // The `audio level` rung renders the Game Boy side with SameBoy's APU, and
    // says it did not run when there is none (metroid2-0b Step 24f).
    if (have_sameboy) {
        verify_mod.link_libc = true;
        addSameBoyApu(b, verify_mod, sameboy_root);
    }
    const verify_exe = b.addExecutable(.{ .name = "verify", .root_module = verify_mod });
    const verify_run = b.addRunArtifact(verify_exe);
    verify_run.step.dependOn(&crawl_run.step);
    verify_run.setCwd(b.path("."));
    verify_run.step.dependOn(test_step);
    if (rom_check) |c| verify_run.step.dependOn(c);

    // ---- Asset extraction --------------------------------------------------
    const extract_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/extract_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    extract_mod_exe.addOptions("build_options", options);
    extract_mod_exe.addImport("testrom", testrom_mod);
    const extract_exe = b.addExecutable(.{ .name = "extract", .root_module = extract_mod_exe });
    const extract_run = b.addRunArtifact(extract_exe);
    extract_run.setCwd(b.path("."));
    b.step("extract", "Extract assets from the ROM into extracted/").dependOn(&extract_run.step);

    // ---- Coverage report ---------------------------------------------------
    const coverage_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/coverage_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    coverage_mod_exe.addOptions("build_options", options);
    coverage_mod_exe.addImport("testrom", testrom_mod);
    const coverage_exe = b.addExecutable(.{ .name = "coverage", .root_module = coverage_mod_exe });
    const coverage_run = b.addRunArtifact(coverage_exe);
    coverage_run.setCwd(b.path("."));
    b.step("coverage", "Print asset coverage: classes read, items derived, bytes reached, what is missing")
        .dependOn(&coverage_run.step);

    // ---- Code probe --------------------------------------------------------
    // ReleaseFast: it runs tens of seconds of emulation and reports addresses,
    // not stack traces.
    const probe_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/probe_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    probe_mod_exe.addOptions("build_options", options);
    probe_mod_exe.addImport("testrom", testrom_mod);
    probe_mod_exe.addImport("png", png_mod);
    const probe_exe = b.addExecutable(.{ .name = "probe", .root_module = probe_mod_exe });
    const probe_run = b.addRunArtifact(probe_exe);
    probe_run.setCwd(b.path("."));
    if (b.args) |args| probe_run.addArgs(args);
    b.step("probe", "Find the code that reads the door script region, by watching the game read it")
        .dependOn(&probe_run.step);

    // ---- Reference frames --------------------------------------------------
    const frames_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/frames_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    frames_mod_exe.addOptions("build_options", options);
    frames_mod_exe.addImport("testrom", testrom_mod);
    frames_mod_exe.addImport("png", png_mod);
    const frames_exe = b.addExecutable(.{ .name = "frames", .root_module = frames_mod_exe });
    const frames_run = b.addRunArtifact(frames_exe);
    frames_run.setCwd(b.path("."));
    b.step("frames", "Render a reference frame for every in-use map screen into extracted/frames/")
        .dependOn(&frames_run.step);

    // ---- Disassembler ------------------------------------------------------
    const disasm_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/disasm_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    disasm_mod_exe.addOptions("build_options", options);
    disasm_mod_exe.addImport("testrom", testrom_mod);
    const disasm_exe = b.addExecutable(.{ .name = "disasm", .root_module = disasm_mod_exe });
    const disasm_run = b.addRunArtifact(disasm_exe);
    disasm_run.setCwd(b.path("."));
    if (b.args) |args| disasm_run.addArgs(args);
    b.step("disasm", "Disassemble a region of the ROM: [bank] [start] [end] [entry...]")
        .dependOn(&disasm_run.step);

    // ---- Logic ledger ------------------------------------------------------
    // ReleaseFast: it emulates minutes of the game and disassembles six banks
    // to a fixpoint, and what it reports is a table rather than a stack trace.
    const ledger_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/ledger_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    ledger_mod_exe.addOptions("build_options", options);
    ledger_mod_exe.addImport("testrom", testrom_mod);
    ledger_mod_exe.addImport("png", png_mod);
    const ledger_exe = b.addExecutable(.{ .name = "ledger", .root_module = ledger_mod_exe });
    const ledger_run = b.addRunArtifact(ledger_exe);
    ledger_run.setCwd(b.path("."));
    if (b.args) |args| ledger_run.addArgs(args);
    b.step("ledger", "Build the logic inventory ledger: [boot_s] [explore_s] [door_stride]")
        .dependOn(&ledger_run.step);

    // ---- 1.0's backlog, from the ROM (1.0 Step 1) ---------------------------
    const roster_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/roster_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    roster_mod_exe.addOptions("build_options", options);
    roster_mod_exe.addImport("testrom", testrom_mod);
    const roster_exe = b.addExecutable(.{ .name = "roster", .root_module = roster_mod_exe });
    const roster_run = b.addRunArtifact(roster_exe);
    roster_run.step.dependOn(&crawl_run.step);
    roster_run.setCwd(b.path("."));
    if (b.args) |args| roster_run.addArgs(args);
    b.step("roster", "Print the ROM's AI census, Metroid roster, warp destinations and door-op coverage; `ai <addr>` lists one AI's records")
        .dependOn(&roster_run.step);

    // ---- The Queen's room on the Game Boy (1.0 Step 6) ----------------------
    const queen_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/queen_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    queen_mod_exe.addOptions("build_options", options);
    queen_mod_exe.addImport("testrom", testrom_mod);
    addShimpkg(b, queen_mod_exe);
    addEngine(b, queen_mod_exe);
    const queen_exe = b.addExecutable(.{ .name = "queen", .root_module = queen_mod_exe });
    const queen_run = b.addRunArtifact(queen_exe);
    queen_run.setCwd(b.path("."));
    if (b.args) |args| queen_run.addArgs(args);
    b.step("queen", "The Queen's room on the Game Boy: [frames] [every], `scenario` to write build-out/queen.{sfc,lua}, or `oracle` for build-out/queen_fight.{sfc,lua}")
        .dependOn(&queen_run.step);

    // ---- The `credits` rung on its own (1.0 Step 22c) ------------------------
    const credits_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/credits_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    credits_mod_exe.addOptions("build_options", options);
    credits_mod_exe.addImport("testrom", testrom_mod);
    addShimpkg(b, credits_mod_exe);
    addEngine(b, credits_mod_exe);
    const credits_exe = b.addExecutable(.{ .name = "credits", .root_module = credits_mod_exe });
    const credits_run = b.addRunArtifact(credits_exe);
    credits_run.setCwd(b.path("."));
    credits_run.has_side_effects = true;
    if (b.args) |args| credits_run.addArgs(args);
    b.step("credits", "The `credits` rung on its own: [clock or fault label ...], each run in Mesen2 from build-out/credits-*")
        .dependOn(&credits_run.step);

    // ---- The table-driven dispatch survey (F4) -----------------------------
    const dispatch_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/dispatch_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    dispatch_mod_exe.addOptions("build_options", options);
    dispatch_mod_exe.addImport("testrom", testrom_mod);
    dispatch_mod_exe.addImport("png", png_mod);
    const dispatch_exe = b.addExecutable(.{ .name = "dispatch", .root_module = dispatch_mod_exe });
    const dispatch_run = b.addRunArtifact(dispatch_exe);
    dispatch_run.setCwd(b.path("."));
    if (b.args) |args| dispatch_run.addArgs(args);
    b.step("dispatch", "Survey the ROM's table-driven dispatch: [boot_s] [explore_s] [door_stride]")
        .dependOn(&dispatch_run.step);

    // ---- The sound engine's Game Boy cost -----------------------------------
    // ReleaseFast: four cases of thirty seconds each, one of them after 3239
    // warm-up calls, all under an execution watch.
    const audiocost_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/audiocost_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audiocost_mod_exe.addOptions("build_options", options);
    audiocost_mod_exe.addImport("testrom", testrom_mod);
    audiocost_mod_exe.addImport("png", png_mod);
    const audiocost_exe = b.addExecutable(.{ .name = "audiocost", .root_module = audiocost_mod_exe });
    const audiocost_run = b.addRunArtifact(audiocost_exe);
    audiocost_run.setCwd(b.path("."));
    b.step("audiocost", "T-cycles per handleAudio call on the Game Boy, and the routines they go to")
        .dependOn(&audiocost_run.step);

    // ---- TAS replay --------------------------------------------------------
    // ReleaseFast, and not optionally: a full replay is 45 minutes of emulated
    // Game Boy, which is billions of instructions.
    const tas_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/tas_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    tas_mod_exe.addOptions("build_options", options);
    tas_mod_exe.addImport("testrom", testrom_mod);
    tas_mod_exe.addImport("png", png_mod);
    const tas_exe = b.addExecutable(.{ .name = "tas", .root_module = tas_mod_exe });
    const tas_run = b.addRunArtifact(tas_exe);
    tas_run.setCwd(b.path("."));
    if (b.args) |args| tas_run.addArgs(args);
    b.step("tas", "Replay a published TAS and trace it: [any|100] [frames] [stride] [lcd|cycles]")
        .dependOn(&tas_run.step);

    // ---- The Game Boy reference trace --------------------------------------
    const gb_trace_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/gb_trace_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    gb_trace_mod_exe.addOptions("build_options", options);
    gb_trace_mod_exe.addImport("testrom", testrom_mod);
    gb_trace_mod_exe.addImport("png", png_mod);
    const gb_trace_exe = b.addExecutable(.{ .name = "gbtrace", .root_module = gb_trace_mod_exe });
    const gb_trace_run = b.addRunArtifact(gb_trace_exe);
    gb_trace_run.setCwd(b.path("."));
    if (b.args) |args| gb_trace_run.addArgs(args);
    gb_trace_run.step.dependOn(&crawl_run.step);
    b.step("gbtrace", "Take the reference trace off Mesen2: [movie] [first] [count]")
        .dependOn(&gb_trace_run.step);

    // ---- The oracle --------------------------------------------------------
    const oracle_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/oracle_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    oracle_mod_exe.addOptions("build_options", options);
    oracle_mod_exe.addImport("testrom", testrom_mod);
    oracle_mod_exe.addImport("png", png_mod);
    addEngine(b, oracle_mod_exe);
    const oracle_exe = b.addExecutable(.{ .name = "oracle", .root_module = oracle_mod_exe });
    const oracle_run = b.addRunArtifact(oracle_exe);
    oracle_run.setCwd(b.path("."));
    if (b.args) |args| oracle_run.addArgs(args);
    // `snes_screen.bootFor` reads the crawl (1.0 Step 18c).
    oracle_run.step.dependOn(&crawl_run.step);
    b.step("oracle", "Take the Game Boy reference for the hand-authored segment and write the Mesen2 script")
        .dependOn(&oracle_run.step);

    // ---- The frame trace ----------------------------------------------------
    const trace_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/trace_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    trace_mod_exe.addOptions("build_options", options);
    trace_mod_exe.addImport("testrom", testrom_mod);
    trace_mod_exe.addImport("png", png_mod);
    addEngine(b, trace_mod_exe);
    const trace_exe = b.addExecutable(.{ .name = "trace", .root_module = trace_mod_exe });
    const trace_run = b.addRunArtifact(trace_exe);
    trace_run.step.dependOn(&crawl_run.step);
    trace_run.setCwd(b.path("."));
    if (b.args) |args| trace_run.addArgs(args);
    b.step("trace", "Record the cart's own state for every frame of the oracle's segment: [first] [count]")
        .dependOn(&trace_run.step);

    // ---- The cart's audio ticks against the original's (metroid2-audio 16a) ----
    const audioparity_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/audioparity_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audioparity_mod_exe.addOptions("build_options", options);
    audioparity_mod_exe.addImport("testrom", testrom_mod);
    audioparity_mod_exe.addImport("png", png_mod);
    addEngine(b, audioparity_mod_exe);
    const audioparity_exe = b.addExecutable(.{ .name = "audioparity", .root_module = audioparity_mod_exe });
    const audioparity_run = b.addRunArtifact(audioparity_exe);
    audioparity_run.setCwd(b.path("."));
    if (b.args) |args| audioparity_run.addArgs(args);
    const audiosites_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/audiosites_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    audiosites_mod_exe.addOptions("build_options", options);
    audiosites_mod_exe.addImport("testrom", testrom_mod);
    audiosites_mod_exe.addImport("png", png_mod);
    const audiosites_run = b.addRunArtifact(b.addExecutable(.{ .name = "audiosites", .root_module = audiosites_mod_exe }));
    audiosites_run.setCwd(b.path("."));
    if (b.args) |args| audiosites_run.addArgs(args);
    b.step("audiosites", "List every Game Boy sound-request site and what the port does with it: [missing|unported|...]")
        .dependOn(&audiosites_run.step);
    b.step("audioparity", "Grade the cart's handleAudio ticks against the Game Boy's over the any% run: [stretch]")
        .dependOn(&audioparity_run.step);
    const audioboot_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/audioboot_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    audioboot_mod_exe.addOptions("build_options", options);
    audioboot_mod_exe.addImport("testrom", testrom_mod);
    audioboot_mod_exe.addImport("png", png_mod);
    addEngine(b, audioboot_mod_exe);
    const audioboot_run = b.addRunArtifact(b.addExecutable(.{ .name = "audioboot", .root_module = audioboot_mod_exe }));
    audioboot_run.setCwd(b.path("."));
    b.step("audioboot", "Boot the shipped cart in Mesen2 with and without sound: the upload's frames, and the timeout path")
        .dependOn(&audioboot_run.step);

    // The A/B (metroid2-audio Step 17): one request rendered by both engines,
    // two WAVs to listen to. Unlike every other audio step this one can be
    // missing its renderer on a machine that has the ROM — SameBoy is vendored
    // and `vendor/` is not tracked — so it says so, and says which script
    // fetches it. Only `Core/*.c` is built here, which needs neither rgbds nor
    // SDL, though the script that clones it builds its tester too.
    const audioab_step = b.step("audioab", "Render one song or effect on both engines to adjacent WAVs: song <id> | sfx <chan> <id>");
    if (have_sameboy) {
        const audioab_mod_exe = b.createModule(.{
            .root_source_file = b.path("src/audioab_main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        audioab_mod_exe.addOptions("build_options", options);
        audioab_mod_exe.addImport("testrom", testrom_mod);
        audioab_mod_exe.addImport("png", png_mod);
        addShimpkg(b, audioab_mod_exe);
        addSameBoyApu(b, audioab_mod_exe, sameboy_root);
        const audioab_run = b.addRunArtifact(b.addExecutable(.{ .name = "audioab", .root_module = audioab_mod_exe }));
        audioab_run.setCwd(b.path("."));
        audioab_run.has_side_effects = true;
        if (b.args) |args| audioab_run.addArgs(args);
        audioab_step.dependOn(&audioab_run.step);
    } else {
        audioab_step.dependOn(&b.addFail(
            \\audioab: no SameBoy at vendor/sameboy, and it is the reference the
            \\Game Boy side is rendered by.
            \\  Get it:  tools/sameboy-frames.sh   (it clones the pinned tag)
            \\Only Core/*.c is built for this step, by build.zig rather than by
            \\SameBoy's Makefile.
        ).step);
    }

    // ---- SNES conversion ---------------------------------------------------
    const convert_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/convert_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    convert_mod_exe.addOptions("build_options", options);
    convert_mod_exe.addImport("testrom", testrom_mod);
    // `zig build convert` ends with the ARAM layout, which reads its region
    // bounds out of the synced shim package; and the converted set now carries
    // the audio image and the title's "Super", so it needs both embeds
    // (`addAudio`, which adds the shim package too). The gate's layout-failure
    // message sends a reader here, so it has to build.
    addAudio(b, convert_mod_exe);
    const convert_exe = b.addExecutable(.{ .name = "convert", .root_module = convert_mod_exe });
    const convert_run = b.addRunArtifact(convert_exe);
    convert_run.step.dependOn(&crawl_run.step);
    convert_run.setCwd(b.path("."));
    b.step("convert", "Convert the ROM's assets to SNES form and report them against the region layout")
        .dependOn(&convert_run.step);

    // The ARAM image itself (metroid2-audio Step 6). A build product, not
    // committed: it is a function of the ROM, engine/audio.bin and audio/shim/.
    const aram_image_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/aram_image_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    aram_image_mod_exe.addOptions("build_options", options);
    aram_image_mod_exe.addImport("testrom", testrom_mod);
    addShimpkg(b, aram_image_mod_exe);
    const aram_image_exe = b.addExecutable(.{ .name = "aramimage", .root_module = aram_image_mod_exe });
    const aram_image_run = b.addRunArtifact(aram_image_exe);
    aram_image_run.setCwd(b.path("."));
    if (b.args) |args| aram_image_run.addArgs(args);
    b.step("aramimage", "Write the SPC700's ARAM image to build-out/aram.bin")
        .dependOn(&aram_image_run.step);

    // The comparison itself (metroid2-audio Step 6): one request script through
    // both engines, and the first tick where they disagree.
    const audiocmp_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/audiocmp_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audiocmp_mod_exe.addOptions("build_options", options);
    audiocmp_mod_exe.addImport("testrom", testrom_mod);
    addShimpkg(b, audiocmp_mod_exe);
    const audiocmp_exe = b.addExecutable(.{ .name = "audiocmp", .root_module = audiocmp_mod_exe });
    const audiocmp_run = b.addRunArtifact(audiocmp_exe);
    audiocmp_run.setCwd(b.path("."));
    if (b.args) |args| audiocmp_run.addArgs(args);
    b.step("audiocmp", "Grade the SPC700 sound engine against the Game Boy on a .req script")
        .dependOn(&audiocmp_run.step);

    // And what it costs (metroid2-audio Step 7). Offline; the verdict's method
    // is `zig build audiobench -- --image` on the console.
    const audioload_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/audioload_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    audioload_mod_exe.addOptions("build_options", options);
    audioload_mod_exe.addImport("testrom", testrom_mod);
    addShimpkg(b, audioload_mod_exe);
    const audioload_exe = b.addExecutable(.{ .name = "audioload", .root_module = audioload_mod_exe });
    const audioload_run = b.addRunArtifact(audioload_exe);
    audioload_run.setCwd(b.path("."));
    if (b.args) |args| audioload_run.addArgs(args);
    b.step("audioload", "Measure what the SPC700 sound engine costs, offline, on a .req script")
        .dependOn(&audioload_run.step);

    // ---- Inspection and A/B tooling ----------------------------------------
    const inspect_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/inspect_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    inspect_mod_exe.addOptions("build_options", options);
    inspect_mod_exe.addImport("testrom", testrom_mod);
    inspect_mod_exe.addImport("png", png_mod);
    const inspect_exe = b.addExecutable(.{ .name = "inspect", .root_module = inspect_mod_exe });
    const inspect_run = b.addRunArtifact(inspect_exe);
    inspect_run.setCwd(b.path("."));
    if (b.args) |args| inspect_run.addArgs(args);
    b.step("inspect", "Look at the conversion: A/B images, contact sheets, and the asset viewer")
        .dependOn(&inspect_run.step);

    // ---- ROM build (release Step 6) -----------------------------------------
    //
    // The carts are the `m2snes` binary's, run on the configured ROM with the
    // crawl `zig build crawl` cached, so there is one pipeline: what the gate
    // grades is what a player runs. `zig build rom [-- --debug]` writes one
    // into build-out/ with its symbol file, then the previews.
    const previews_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/previews_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    previews_mod_exe.addOptions("build_options", options);
    previews_mod_exe.addImport("testrom", testrom_mod);
    previews_mod_exe.addImport("png", png_mod);
    addEngine(b, previews_mod_exe);
    const previews_run = b.addRunArtifact(b.addExecutable(.{ .name = "previews", .root_module = previews_mod_exe }));
    previews_run.step.dependOn(&crawl_run.step);
    previews_run.setCwd(b.path("."));
    previews_run.has_side_effects = true;
    b.step("previews", "Render the cart's first frame and title to build-out/*.png, and print its layout")
        .dependOn(&previews_run.step);

    const rom_debug = if (b.args) |args| for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) break true;
    } else false else false;
    const rom_run = cartRun(b, exe, rom_path, rom_debug, &crawl_run.step, rom_check);
    previews_run.step.dependOn(&rom_run.step);
    b.step("rom", "Build the SNES ROM with the m2snes binary into build-out/ (-- --debug for the debug cart), then the previews")
        .dependOn(&previews_run.step);

    // ---- The output pins (release Step 1) ----------------------------------
    //
    // Both carts, made fresh for the gate's `cart pin` rung and for `repin`,
    // which hash them against `pins/cart.txt` (`src/pin.zig`).
    const cart_retail_run = cartRun(b, exe, rom_path, false, &crawl_run.step, rom_check);
    const cart_debug_run = cartRun(b, exe, rom_path, true, &crawl_run.step, rom_check);
    verify_run.step.dependOn(&cart_retail_run.step);
    verify_run.step.dependOn(&cart_debug_run.step);

    // The gate's `pin (binary)` rung runs the binary itself, from a working
    // directory of its own; its path is the gate's first argument.
    verify_run.addArtifactArg(exe);

    // `zig build pin-check`: both carts from the binary with no crawl cache,
    // the player's run, against the pins. `-Dtarget=` grades another target's
    // binary that this machine can run (release Step 7's macOS check). The
    // checker itself is built for the host.
    const pincheck_mod = b.createModule(.{
        .root_source_file = b.path("src/pincheck_main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const pincheck_exe = b.addExecutable(.{ .name = "pincheck", .root_module = pincheck_mod });
    const pincheck_run = pinCheckRun(b, pincheck_exe, exe, rom_path, rom_check);
    b.step("pin-check", "Run the m2snes binary as a player does (no crawl cache) for both carts, against pins/cart.txt")
        .dependOn(&pincheck_run.step);

    // `zig build cart-pin` (release Step 9): the same, reading the cached
    // crawl, in seconds. The pre-push hook's pin rung.
    const cart_pin_run = b.addRunArtifact(pincheck_exe);
    cart_pin_run.setCwd(b.path("."));
    cart_pin_run.has_side_effects = true;
    cart_pin_run.addArg("cached");
    cart_pin_run.addArtifactArg(exe);
    cart_pin_run.addArg(rom_path);
    cart_pin_run.addArg("build-out");
    _ = cart_pin_run.addOutputDirectoryArg("cart-pin");
    cart_pin_run.step.dependOn(&crawl_run.step);
    if (rom_check) |c| cart_pin_run.step.dependOn(c);
    b.step("cart-pin", "Run the m2snes binary on the cached crawl for both carts, against pins/cart.txt")
        .dependOn(&cart_pin_run.step);

    // The binary on every ROM refusal and on its own input as output. No ROM
    // needed, so it is part of `test`.
    const refusals_run = b.addRunArtifact(pincheck_exe);
    refusals_run.has_side_effects = true;
    refusals_run.addArg("refusals");
    refusals_run.addArtifactArg(exe);
    _ = refusals_run.addOutputDirectoryArg("refusals");
    test_step.dependOn(&refusals_run.step);

    const repin_mod = b.createModule(.{
        .root_source_file = b.path("src/repin_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    repin_mod.addOptions("build_options", options);
    repin_mod.addImport("testrom", testrom_mod);
    const repin_run = b.addRunArtifact(b.addExecutable(.{ .name = "repin", .root_module = repin_mod }));
    repin_run.step.dependOn(&cart_debug_run.step);
    repin_run.setCwd(b.path("."));
    repin_run.has_side_effects = true;
    if (b.args) |args| repin_run.addArgs(args);
    if (rom_check) |c| repin_run.step.dependOn(c);
    b.step("repin", "Move pins/cart.txt to this tree's output and log why in pins/history.md: -- \"<why>\"")
        .dependOn(&repin_run.step);

    // ---- History audit (release Step 2) ------------------------------------
    //
    // The file policy over every blob in a repository's history, for going
    // public: `-- <git-dir> [extra-sha...]` (`src/history_audit_main.zig`).
    const history_audit_mod = b.createModule(.{
        .root_source_file = b.path("src/history_audit_main.zig"),
        .target = target,
        // ReleaseSafe: a first push audits all of history (about 250 MB of
        // blobs), which Debug takes a minute over.
        .optimize = .ReleaseSafe,
    });
    history_audit_mod.addOptions("build_options", options);
    history_audit_mod.addImport("testrom", testrom_mod);
    const history_audit_run = b.addRunArtifact(b.addExecutable(.{ .name = "history-audit", .root_module = history_audit_mod }));
    history_audit_run.has_side_effects = true;
    if (b.args) |args| history_audit_run.addArgs(args);
    if (rom_check) |c| history_audit_run.step.dependOn(c);
    b.step("history-audit", "The file policy over every blob in a git history: -- <git-dir> [extra-sha...] | --revs <rev-list args...>")
        .dependOn(&history_audit_run.step);

    // The file policy alone, ROM or no ROM (release Step 9): CI runs it with
    // none, and the pre-commit hook runs it with `-- --staged`
    // (`src/policy_main.zig`). Without a ROM the n-gram scan prints
    // `not run:`, and the size ceiling and forbidden paths still hold.
    const policy_main_mod = b.createModule(.{
        .root_source_file = b.path("src/policy_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    policy_main_mod.addOptions("build_options", options);
    policy_main_mod.addImport("testrom", testrom_mod);
    const policy_run = b.addRunArtifact(b.addExecutable(.{ .name = "policy", .root_module = policy_main_mod }));
    policy_run.setCwd(b.path("."));
    policy_run.has_side_effects = true;
    if (b.args) |args| policy_run.addArgs(args);
    b.step("policy", "The tracked-file policy, with or without the ROM: [-- --staged] for the blobs the next commit adds")
        .dependOn(&policy_run.step);

    // ---- Mesen2 ROM test ---------------------------------------------------
    const romtest_mod = b.createModule(.{
        .root_source_file = b.path("src/romtest_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    romtest_mod.addOptions("build_options", options);
    romtest_mod.addImport("testrom", testrom_mod);
    romtest_mod.addImport("png", png_mod);
    addEngine(b, romtest_mod);
    const romtest_exe = b.addExecutable(.{ .name = "romtest", .root_module = romtest_mod });
    const romtest_run = b.addRunArtifact(romtest_exe);
    romtest_run.step.dependOn(&crawl_run.step);
    romtest_run.setCwd(b.path("."));
    if (b.args) |args| romtest_run.addArgs(args);
    b.step("romtest", "Generate build-out/m2snes.lua, the Mesen2 test for the finished cart")
        .dependOn(&romtest_run.step);

    // ---- Engine assembly (dev time only) -----------------------------------
    //
    // Not a dependency of anything: `engine.bin` and `engine.sym` are
    // committed, so a build never needs an assembler. This step is how they are
    // regenerated, and `verify` reports whether the committed pair still
    // matches `engine/main.asm`.
    const engine_run = b.addSystemCommand(&.{"tools/build-engine.sh"});
    engine_run.setCwd(b.path("."));
    engine_run.has_side_effects = true;
    b.step("engine", "Reassemble engine/engine.bin and engine.sym from engine/main.asm (needs asar)")
        .dependOn(&engine_run.step);

    // The same bargain on the SPC700 side (metroid2-audio Step 4). The sound
    // engine assembles against `audio/shim/shim_abi.inc`, the ABI the synced
    // shim package carries, and `verify` reassembles it the same way.
    //
    // Where bank 4's data landed in ARAM is `aram_layout.plan`'s decision, and
    // the engine reads those addresses out of a generated include rather than
    // restating them. Generating it is a step of its own because it needs
    // neither the ROM nor an assembler, and `spcengine` depends on it so the
    // include is current before the assembler reads it.
    const aramsyms_mod_exe = b.createModule(.{
        .root_source_file = b.path("src/aramsyms_main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    aramsyms_mod_exe.addOptions("build_options", options);
    aramsyms_mod_exe.addImport("testrom", testrom_mod);
    addShimpkg(b, aramsyms_mod_exe);
    const aramsyms_exe = b.addExecutable(.{ .name = "aramsyms", .root_module = aramsyms_mod_exe });
    const aramsyms_run = b.addRunArtifact(aramsyms_exe);
    aramsyms_run.setCwd(b.path("."));
    aramsyms_run.has_side_effects = true;
    b.step("aramsyms", "Regenerate engine/audio/aram_data.inc from the ARAM layout")
        .dependOn(&aramsyms_run.step);

    const spcengine_run = b.addSystemCommand(&.{"tools/build-spcengine.sh"});
    spcengine_run.setCwd(b.path("."));
    spcengine_run.has_side_effects = true;
    spcengine_run.step.dependOn(&aramsyms_run.step);
    b.step("spcengine", "Reassemble engine/audio.bin and audio.mlb from engine/audio/main.asm (needs spc700asm)")
        .dependOn(&spcengine_run.step);

    const verify_step = b.step("verify", "The gate: unit tests, file policy, and the ROM checks (fails without a ROM)");
    verify_step.dependOn(&verify_run.step);

    // ---- The slow tier (1.0 Step 18c2) --------------------------------------
    //
    // The gate, then the rungs too slow for it, one after another. Run at the
    // close of any step that touches the world, the boots or the seeding, and
    // at consolidation.
    //
    // First rung: the seeding fixture, held to its pins
    // (`oracle.seeding_catches`, `oracle.seeding_frames_floor`).
    const seeding_run = b.addRunArtifact(oracle_exe);
    seeding_run.setCwd(b.path("."));
    seeding_run.addArgs(&.{ "recorded", "10000", "2000", "8", "fault" });
    seeding_run.has_side_effects = true;
    seeding_run.step.dependOn(&crawl_run.step);
    seeding_run.step.dependOn(&verify_run.step);

    // Second rung: the recording's worlds, held to `src/worlds_misses.txt`.
    // Cold it replays the recording in Mesen, eight lanes at once, in about
    // five minutes; Mesen's answers are cached in `build-out/mesen-cache/`, so
    // a re-grade of a new reading takes seconds.
    const worlds_run = b.addRunArtifact(gb_trace_exe);
    worlds_run.setCwd(b.path("."));
    worlds_run.addArgs(&.{ "reference/metroid2-100p-recording", "set", "worlds" });
    worlds_run.has_side_effects = true;
    worlds_run.step.dependOn(&seeding_run.step);

    // Third rung (1.0 Step 22c): the `credits` rung, six clocks and four
    // faults, each run thousands of passes from our Game Boy's lever and
    // through the menu on the cart: three minutes the gate's budget had not.
    const credits_full_run = b.addRunArtifact(credits_exe);
    credits_full_run.setCwd(b.path("."));
    credits_full_run.has_side_effects = true;
    credits_full_run.step.dependOn(&worlds_run.step);

    // Fourth and fifth rungs (release Steps 0 and 4): `crawl cold`, a crawl
    // from scratch against the cached one, so a stale cache cannot grade the
    // gate unseen; and `crawl jobs`, the same crawl on 1, 2 and every logical
    // CPU's lanes, which must give the same bytes and counters.
    const crawl_check_run = b.addRunArtifact(crawl_exe);
    crawl_check_run.setCwd(b.path("."));
    crawl_check_run.addArg("check");
    crawl_check_run.has_side_effects = true;
    crawl_check_run.step.dependOn(&credits_full_run.step);

    // Sixth rung (release Step 6): `pin-check`, the binary as a player runs
    // it, crawling for itself, against the pins. A run of its own, so the
    // chain above stays out of `zig build pin-check`.
    const pincheck_full_run = pinCheckRun(b, pincheck_exe, exe, rom_path, rom_check);
    pincheck_full_run.step.dependOn(&crawl_check_run.step);

    // Seventh rung (release Step 8): `location`, the same cart from two
    // install directories, two working directories, and the ROM by a relative
    // and an absolute path. Reads the crawl the gate cached.
    const location_run = b.addRunArtifact(pincheck_exe);
    location_run.setCwd(b.path("."));
    location_run.has_side_effects = true;
    location_run.addArg("location");
    location_run.addArtifactArg(exe);
    location_run.addArg(rom_path);
    location_run.addArg("build-out");
    _ = location_run.addOutputDirectoryArg("location");
    location_run.step.dependOn(&pincheck_full_run.step);

    const verify_full_step = b.step("verify-full", "The gate, then the slow tier: the seeding fixture, the recording's worlds against their pins, the credits, a crawl from scratch, on one lane and on many, against the cached one, the binary's own crawl against the pins, and the binary from other install and working directories");
    verify_full_step.dependOn(&location_run.step);

    // The gate's `builder` rung: what a plain `zig build` installs, which
    // must be the builder alone. Read here, once every step is declared.
    var installs: std.ArrayList(u8) = .empty;
    for (b.getInstallStep().dependencies.items, 0..) |d, i| {
        if (i != 0) installs.append(b.allocator, ',') catch @panic("OOM");
        const name = if (d.cast(std.Build.Step.InstallArtifact)) |ia| ia.dest_sub_path else d.name;
        installs.appendSlice(b.allocator, name) catch @panic("OOM");
    }
    verify_run.addArg(installs.items);
}

/// Embed the committed engine image and symbol file into a module.
///
/// `@embedFile` cannot reach outside its module's root directory and each
/// `src/` file here is its own module root, so the two files arrive as named
/// imports rather than relative paths.
/// The synced shim package's generated constants, for anything that reads the
/// ARAM map. Like `addEngine`, it arrives as a named import because each file
/// under `src/` is its own module root and cannot reach `audio/shim/`.
fn addShimpkg(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("shimpkg", .{ .root_source_file = b.path("audio/shim/shimpkg.zig") });
}

fn addEngine(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("engine_bin", .{ .root_source_file = b.path("engine/engine.bin") });
    mod.addAnonymousImport("engine_sym", .{ .root_source_file = b.path("engine/engine.sym") });
    // The source too: `src/residue.zig` reads which routines touch which
    // variable, and neither the image nor the symbol file says that.
    mod.addAnonymousImport("engine_asm", .{ .root_source_file = b.path("engine/main.asm") });
    addAudio(b, mod);
}

/// SameBoy's APU, for the A/B's Game Boy side: `src/sbref.c` and the core it
/// drives. Mirrors snes_game_dev's `gbref` recipe, because the two repositories
/// must render the reference with the same player (`src/sbref.c` says why).
///
/// `GB_INTERNAL` is what exposes the core's own struct fields and the entry
/// points `sbref.c` calls — `GB_apu_write` and `GB_advance_cycles` among them.
/// Without it every Core file fails to compile against its own headers, which
/// is SameBoy saying these are not public API. They are not, and the tag the
/// checkout is pinned to is why that is safe.
fn addSameBoyApu(b: *std.Build, mod: *std.Build.Module, root: []const u8) void {
    mod.addIncludePath(b.path(root));
    mod.addIncludePath(b.path(b.pathJoin(&.{ root, "Core" })));
    const flags = [_][]const u8{
        "-std=gnu11",
        "-D_GNU_SOURCE",
        "-DGB_INTERNAL",
        "-DGB_VERSION=\"1.0.2\"",
        "-DGB_COPYRIGHT_YEAR=\"2025\"",
    };
    mod.addCSourceFile(.{ .file = b.path("src/sbref.c"), .flags = &flags });
    mod.addCSourceFiles(.{
        .root = b.path(root),
        // Every C file in the core at the pinned tag. The whole thing rather
        // than an isolated APU: `apu.c` includes `gb.h`, which pulls in the
        // entire machine, and twenty-one files that compile clean are less work
        // than a fork that does not.
        .files = &.{
            "Core/apu.c",          "Core/camera.c",
            "Core/cheat_search.c", "Core/cheats.c",
            "Core/debugger.c",     "Core/display.c",
            "Core/gb.c",           "Core/joypad.c",
            "Core/mbc.c",          "Core/memory.c",
            "Core/printer.c",      "Core/random.c",
            "Core/rewind.c",       "Core/rumble.c",
            "Core/save_state.c",   "Core/sgb.c",
            "Core/sm83_cpu.c",     "Core/sm83_disassembler.c",
            "Core/symbol_hash.c",  "Core/timing.c",
            "Core/workboy.c",
        },
        .flags = &flags,
    });
}

/// The sound engine and the shim package: the converter builds the ARAM image
/// the cart uploads (metroid2-audio Step 16a), so every module that reaches
/// `snes_convert.zig`, directly or not, needs both. And the title's "Super"
/// (metroid2-0b Step 24j), which the converter decodes from its PNG: the file,
/// and `png.zig` as the one shared module, since a module that imported it by
/// path as well as by name would hold the same file twice.
fn addAudio(b: *std.Build, mod: *std.Build.Module) void {
    mod.addAnonymousImport("audio_bin", .{ .root_source_file = b.path("engine/audio.bin") });
    mod.addAnonymousImport("title_super_png", .{ .root_source_file = b.path("assets/title_super.png") });
    mod.addImport("png", png_module.?);
    addShimpkg(b, mod);
}

/// `png.zig`'s module, set where it is created, for `addAudio`.
var png_module: ?*std.Build.Module = null;

/// `build.zig.zon`'s `.version`, for `m2snes --version`.
fn zonVersion(b: *std.Build) []const u8 {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 16)) catch |e|
        std.debug.panic("cannot read build.zig.zon: {s}", .{@errorName(e)});
    return quotedAfter(text, ".version = \"") orelse @panic("build.zig.zon has no .version");
}

/// The targets a release ships (requirements, Feature 5). No Windows arm64:
/// with Zig 0.16 a stripped aarch64-windows binary segfaults at startup on
/// windows-11-arm, even a hello world, and an unstripped one is not
/// reproducible (its PDB GUID hashes the build's absolute paths). Windows on
/// ARM runs the x86_64 binary under emulation; CI smoke-tests it there
/// (release Step 13; docs/feature_tracker.md F15).
const release_targets = [_][]const u8{
    "aarch64-macos",
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-windows-gnu",
};

/// The `m2snes` binary's optimize mode, on every target. ReleaseSafe, so a
/// player's bug report carries a safety panic rather than a wrong cart: on
/// this Mac (2026-10-05) a player's run took 30.4 s against ReleaseFast's
/// 25.6 s (1.19x; the bar was 1.5x), 113 MB against 105 MB, same cart.
const builder_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

/// What every `m2snes` build shares, whatever its target: options with every
/// configure-time path empty, so nothing in it can name the developer's ROM
/// or Mesen (the gate's `builder` rung checks the binary for the path), and
/// the version it reports.
const BuilderOptions = struct {
    build: *std.Build.Step.Options,
    testrom: *std.Build.Step.Options,
    version: *std.Build.Step.Options,

    fn init(b: *std.Build) BuilderOptions {
        const build_opts = b.addOptions();
        build_opts.addOption([]const u8, "rom_path", "");
        build_opts.addOption([]const u8, "mesen_path", "");
        build_opts.addOption(bool, "survey", false);
        build_opts.addOption(bool, "have_sameboy", false);
        const testrom_opts = b.addOptions();
        testrom_opts.addOption([]const u8, "rom_path", "");
        const version = b.addOptions();
        version.addOption([]const u8, "version", zonVersion(b));
        version.addOption([]const u8, "commit", gitCommit(b));
        version.addOption([]const u8, "shim_commit", shimCommit(b));
        return .{ .build = build_opts, .testrom = testrom_opts, .version = version };
    }
};

/// The `m2snes` binary for `target`. Its own `testrom` too, which would
/// otherwise carry the ROM path in. `strip` drops the debug info, and with it
/// every build-host path; release binaries are stripped.
fn builderExe(
    b: *std.Build,
    opts: BuilderOptions,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
) *std.Build.Step.Compile {
    const testrom_mod = b.createModule(.{
        .root_source_file = b.path("src/testrom.zig"),
        .target = target,
        .optimize = optimize,
    });
    testrom_mod.addOptions("testrom_options", opts.testrom);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    mod.addOptions("build_options", opts.build);
    mod.addOptions("version_info", opts.version);
    mod.addImport("testrom", testrom_mod);
    addEngine(b, mod);
    return b.addExecutable(.{ .name = "m2snes", .root_module = mod });
}

/// The commit `m2snes --version` names: the hash, 12 digits, with `-dirty`
/// when the tree has uncommitted changes; `unknown` where there is no git or
/// no repository (a source tarball). Never `git describe`, whose answer
/// differs between a tag checkout and a branch at the same commit, so CI and
/// a local build of one commit embed the same string.
fn gitCommit(b: *std.Build) []const u8 {
    const root = b.build_root.path orelse ".";
    var code: u8 = 0;
    const head = b.runAllowFail(&.{ "git", "-C", root, "rev-parse", "--short=12", "HEAD" }, &code, .ignore) catch
        return "unknown";
    const status = b.runAllowFail(&.{ "git", "-C", root, "status", "--porcelain" }, &code, .ignore) catch
        return "unknown";
    const hash = std.mem.trim(u8, head, " \t\r\n");
    return if (std.mem.trim(u8, status, " \t\r\n").len == 0) hash else b.fmt("{s}-dirty", .{hash});
}

/// The snes_game_dev commit the synced audio shim was generated at.
fn shimCommit(b: *std.Build) []const u8 {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, "audio/shim/MANIFEST", b.allocator, .limited(1 << 16)) catch |e|
        std.debug.panic("cannot read audio/shim/MANIFEST: {s}", .{@errorName(e)});
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "commit ")) return std.mem.trim(u8, line["commit ".len..], " \t\r");
    }
    @panic("audio/shim/MANIFEST has no commit line");
}

fn quotedAfter(text: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, prefix) orelse return null;
    const rest = text[at + prefix.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return null];
}

/// `pincheck pins`: both carts from `exe` with no crawl cache, against the pins.
fn pinCheckRun(
    b: *std.Build,
    pincheck_exe: *std.Build.Step.Compile,
    exe: *std.Build.Step.Compile,
    rom_path: []const u8,
    rom_check: ?*std.Build.Step,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(pincheck_exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.addArg("pins");
    run.addArtifactArg(exe);
    run.addArg(rom_path);
    _ = run.addOutputDirectoryArg("pin-check");
    if (rom_check) |c| run.step.dependOn(c);
    return run;
}

/// One cart from the `m2snes` binary into build-out/, with its symbol file,
/// reading the crawl `zig build crawl` cached there.
fn cartRun(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    rom_path: []const u8,
    debug: bool,
    crawl: *std.Build.Step,
    rom_check: ?*std.Build.Step,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    run.addArgs(&.{ rom_path, "--crawl-cache", "build-out", "--sym", "-o" });
    run.addArg(if (debug) "build-out/m2snes-debug.sfc" else "build-out/m2snes.sfc");
    if (debug) run.addArg("--debug");
    run.step.dependOn(crawl);
    if (rom_check) |c| run.step.dependOn(c);
    return run;
}
