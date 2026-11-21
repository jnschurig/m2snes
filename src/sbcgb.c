// SameBoy as a Game Boy Color running a CGB-only ROM: the EJRTQ oracle's
// correctness check (colorization Step 5).
//
// Boots `rom` on a CGB with SameBoy's own boot ROM, optionally with a battery
// save, holds the given buttons frame by frame, and stops after `frames`
// frames. It reports what the static model is checked against: both VRAM
// banks, OAM, the LCD registers, EJRTQ's WRAM table at $D200-$D37F, and, per
// VRAM tile, which ROM tile was last copied there.
//
// That last one is tracked the way `src/ejrtq_cover.zig` tracks it in Mesen.
// A write to a tile's first byte in VRAM bank 0 takes its source from HL-1,
// HL or DE, in the bank mapped at $4000, when that address is the first byte
// of a graphics tile (`tile_start`, one bit per ROM byte: regions need not be
// 16-byte aligned, the title's starts at 05:5F34) and holds
// the value written. Anything else marks the tile unknown.
//
// `GB_INTERNAL` (set in build.zig, as for `sbref.c`) exposes the registers,
// the MBC bank and the VRAM bank as struct fields.

#include <stdlib.h>
#include <string.h>
#include "gb.h"

#define SBCGB_INITIAL 0xFFFFFFFEu
#define SBCGB_UNKNOWN 0xFFFFFFFFu

typedef struct {
    uint32_t src[384];
    uint8_t vram[0x4000];
    uint8_t oam[0xA0];
    uint8_t table[0x180];
    uint8_t lcdc, scy, scx, wy, wx, game_mode, samus_oam_end, oam_end;
    uint32_t frames;
    uint32_t named;
    uint32_t unnamed;
    // The first unnamed write, for diagnosis: PC, HL, DE, the bank at $4000,
    // the VRAM address and the value. Clears (value 0) are skipped.
    uint16_t miss_pc, miss_hl, miss_de, miss_bank, miss_addr;
    uint8_t miss_data;
} sbcgb_out_t;

typedef struct {
    GB_gameboy_t gb;
    const uint8_t *rom;
    size_t rom_len;
    const uint8_t *tile_start;
    sbcgb_out_t *out;
    uint8_t *modes;
    size_t nmodes;
    uint32_t frames;
    uint32_t screen[160 * 144];
} sbcgb_t;

static uint32_t rgb_encode(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b)
{
    (void)gb;
    return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

static void on_log(GB_gameboy_t *gb, const char *string, GB_log_attributes_t attributes)
{
    (void)gb;
    (void)string;
    (void)attributes;
}

static void on_vblank(GB_gameboy_t *gb, GB_vblank_type_t type)
{
    (void)type;
    sbcgb_t *self = (sbcgb_t *)gb;
    if (self->modes && self->frames < self->nmodes) self->modes[self->frames] = GB_safe_read_memory(gb, 0xFF9B);
    self->frames++;
}

// The flat ROM offset of CPU address `a`, or -1 outside ROM.
static int64_t flat_of(sbcgb_t *self, uint16_t a)
{
    if (a < 0x4000) return a;
    if (a < 0x8000) return (int64_t)self->gb.mbc_rom_bank * 0x4000 + (a - 0x4000);
    return -1;
}

static bool on_write(GB_gameboy_t *gb, uint16_t addr, uint8_t data)
{
    sbcgb_t *self = (sbcgb_t *)gb;
    if (addr < 0x8000 || addr >= 0x9800 || (addr & 15) != 0 || gb->cgb_vram_bank) return true;
    unsigned t = (addr - 0x8000) >> 4;
    uint16_t cands[3] = {(uint16_t)(gb->hl - 1), gb->hl, gb->de};
    for (unsigned i = 0; i < 3; i++) {
        int64_t fl = flat_of(self, cands[i]);
        if (fl < 0 || (size_t)fl >= self->rom_len) continue;
        if (!(self->tile_start[fl >> 3] & (1u << (fl & 7)))) continue;
        if (self->rom[fl] != data) continue;
        self->out->src[t] = (uint32_t)fl;
        self->out->named++;
        return true;
    }
    self->out->src[t] = SBCGB_UNKNOWN;
    self->out->unnamed++;
    if (data != 0 && self->out->miss_addr == 0 && gb->boot_rom_finished) {
        self->out->miss_pc = gb->pc;
        self->out->miss_hl = gb->hl;
        self->out->miss_de = gb->de;
        self->out->miss_bank = gb->mbc_rom_bank;
        self->out->miss_addr = addr;
        self->out->miss_data = data;
    }
    return true;
}

// `keys[f]` is held during frame f, as SameBoy's key mask (bit 0 right, 1
// left, 2 up, 3 down, 4 A, 5 B, 6 select, 7 start). Past the end, nothing is
// held. `modes`, if given, gets $FF9B (the game mode) at each frame's vblank.
// Returns false if the boot ROM never handed over.
bool sbcgb_run(const uint8_t *rom, size_t rom_len,
               const uint8_t *boot, size_t boot_len,
               const uint8_t *battery, size_t battery_len,
               const uint8_t *tile_start,
               const uint8_t *keys, size_t nkeys,
               unsigned frames,
               uint8_t *modes, size_t nmodes,
               sbcgb_out_t *out)
{
    sbcgb_t *self = calloc(1, sizeof(sbcgb_t));
    if (!self) return false;
    memset(out, 0, sizeof(*out));
    for (unsigned t = 0; t < 384; t++) out->src[t] = SBCGB_INITIAL;
    self->rom = rom;
    self->rom_len = rom_len;
    self->tile_start = tile_start;
    self->out = out;
    self->modes = modes;
    self->nmodes = nmodes;

    GB_init(&self->gb, GB_MODEL_CGB_E);
    GB_set_log_callback(&self->gb, on_log);
    GB_set_pixels_output(&self->gb, self->screen);
    GB_set_rgb_encode_callback(&self->gb, rgb_encode);
    GB_set_turbo_mode(&self->gb, true, true);
    GB_set_vblank_callback(&self->gb, on_vblank);
    GB_load_boot_rom_from_buffer(&self->gb, boot, boot_len);
    GB_load_rom_from_buffer(&self->gb, rom, rom_len);
    if (battery && battery_len) GB_load_battery_from_buffer(&self->gb, battery, battery_len);
    GB_reset(&self->gb);
    GB_set_write_memory_callback(&self->gb, on_write);

    uint32_t held = 0xFFFFFFFF;
    while (self->frames < frames) {
        uint32_t f = self->frames;
        if (f != held) {
            held = f;
            GB_set_key_mask(&self->gb, (GB_key_mask_t)(f < nkeys ? keys[f] : 0));
        }
        GB_run(&self->gb);
    }
    bool ok = self->gb.boot_rom_finished;

    size_t size;
    uint16_t bank;
    const uint8_t *vram = GB_get_direct_access(&self->gb, GB_DIRECT_ACCESS_VRAM, &size, &bank);
    memcpy(out->vram, vram, size < sizeof(out->vram) ? size : sizeof(out->vram));
    const uint8_t *oam = GB_get_direct_access(&self->gb, GB_DIRECT_ACCESS_OAM, &size, &bank);
    memcpy(out->oam, oam, sizeof(out->oam));
    for (unsigned i = 0; i < 0x180; i++) out->table[i] = GB_safe_read_memory(&self->gb, 0xD200 + i);
    out->lcdc = GB_safe_read_memory(&self->gb, 0xFF40);
    out->scy = GB_safe_read_memory(&self->gb, 0xFF42);
    out->scx = GB_safe_read_memory(&self->gb, 0xFF43);
    out->wy = GB_safe_read_memory(&self->gb, 0xFF4A);
    out->wx = GB_safe_read_memory(&self->gb, 0xFF4B);
    out->game_mode = GB_safe_read_memory(&self->gb, 0xFF9B);
    out->samus_oam_end = GB_safe_read_memory(&self->gb, 0xD064);
    out->oam_end = GB_safe_read_memory(&self->gb, 0xFF8D);
    out->frames = self->frames;

    GB_free(&self->gb);
    free(self);
    return ok;
}
