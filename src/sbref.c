// SameBoy's APU, driven by the writes bank 4's engine made.
//
// This is the reference player: the thing that says what a track is supposed to
// sound like. It is not a second emulator of ours. SameBoy's core is linked as
// it ships and fed through `GB_apu_write`, the same entry point its own memory
// map calls when a game writes $FF10-$FF3F. Everything between that call and a
// sample is SameBoy's.
//
// Why the writes and not the ROM: the writes are what `audiocmp` already grades
// the port by, so the A/B's two sides are the two write streams the comparison
// calls equal, rendered. Playing the ROM instead would put a second machine
// between the engine and the sound, with its own timing to argue about.
//
// COPIED from snes_game_dev `audio/sbref.c`, where the shim itself is graded
// against this core, and copied for the reason the shim package is
// (tools/sync-shim.sh): the two repositories move apart, and the A/B's
// reference must be the same player on both sides or the comparison is between
// two SameBoys. What changes here belongs there too. The only difference is
// where the writes come from -- this repository's Game Boy harness, rather than
// a capture log.
//
// The APU is clocked by DIV, and DIV by `GB_advance_cycles`, so time passes
// here exactly as it does in a running machine -- length counters, envelopes and
// sweep all tick on their own. No cartridge is loaded and the CPU never runs;
// nothing in the advance path reads cartridge memory.

#include <stdlib.h>
#include <string.h>
#include "gb.h"

// GB_gameboy_t is the first member, so a callback that receives the core can
// recover the surrounding struct by casting. SameBoy hands the callback nothing
// else to carry state in.
typedef struct {
    GB_gameboy_t gb;
    int16_t *out;
    size_t cap;
    size_t len;
    size_t dropped;
    // Never looked at. The core renders whether or not anyone is watching, and
    // it renders into a buffer the frontend owns -- so a frontend that wants
    // only sound still has to own one, or the first scanline writes through a
    // null pointer.
    uint32_t screen[160 * 144];
} sbref_t;

static uint32_t rgb_encode(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b)
{
    (void)gb;
    return ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

static void on_sample(GB_gameboy_t *gb, GB_sample_t *sample)
{
    sbref_t *self = (sbref_t *)gb;
    if (self->len + 2 > self->cap) {
        self->dropped++;
        return;
    }
    self->out[self->len++] = sample->left;
    self->out[self->len++] = sample->right;
}

sbref_t *sbref_new(unsigned sample_rate)
{
    sbref_t *self = calloc(1, sizeof(sbref_t));
    if (!self) return NULL;
    GB_init(&self->gb, GB_MODEL_DMG_B);
    GB_set_pixels_output(&self->gb, self->screen);
    GB_set_rgb_encode_callback(&self->gb, rgb_encode);
    // The DMG has a DC-blocking capacitor on its output, and SameBoy models it
    // under this name. Leaving it off -- which is the core's default, because a
    // frontend is expected to choose -- leaves a constant offset of a few
    // thousand on every sample, which is not what the hardware puts out and not
    // what a shim should be graded against. It also swamped the first pitch
    // check: pulse 1 was oscillating a few hundred either side of an offset it
    // never crossed, so nothing looked like a note.
    GB_set_highpass_filter_mode(&self->gb, GB_HIGHPASS_ACCURATE);
    GB_set_sample_rate(&self->gb, sample_rate);
    // Turbo, uncapped, and drawing every frame: without it `GB_timing_sync`
    // sleeps to hold the core at the DMG's own speed, so a thirty-second song
    // took thirty seconds to render. It changes when the core sleeps and
    // nothing the APU does (`timing.c`, `display.c`; `apu.c` never reads it).
    GB_set_turbo_mode(&self->gb, true, true);
    GB_apu_set_sample_callback(&self->gb, on_sample);
    return self;
}

void sbref_free(sbref_t *self)
{
    if (!self) return;
    GB_free(&self->gb);
    free(self);
}

// One APU register write. `reg` is the low byte of the address: $10 for NR10,
// through $3F for the last byte of wave RAM.
void sbref_write(sbref_t *self, uint8_t reg, uint8_t value)
{
    GB_apu_write(&self->gb, reg, value);
}

// Advance `cycles` DMG T-cycles, appending whatever samples fall in that span to
// `out`. Returns the number of int16 values written, which is twice the number
// of frames, because the callback is stereo.
//
// `GB_advance_cycles` takes a uint8_t, so the span is walked in small steps --
// four cycles, one machine cycle, which is the granularity the CPU itself
// advances time at.
size_t sbref_advance(sbref_t *self, uint32_t cycles, int16_t *out, size_t cap)
{
    self->out = out;
    self->cap = cap;
    self->len = 0;
    while (cycles >= 4) {
        GB_advance_cycles(&self->gb, 4);
        cycles -= 4;
    }
    if (cycles) GB_advance_cycles(&self->gb, (uint8_t)cycles);
    self->out = NULL;
    self->cap = 0;
    return self->len;
}

// Samples the caller's buffer had no room for. Nonzero means the render is
// wrong and the buffer needs to be bigger; it is never a rounding detail.
size_t sbref_dropped(sbref_t *self)
{
    return self->dropped;
}

// Silence one channel: 0 = pulse 1, 1 = pulse 2, 2 = wave, 3 = noise.
//
// Soloing a channel is what makes the render checkable without a person: with
// the other three muted, the fundamental coming out of the mixer is the one the
// log's period registers asked for, and a frequency measured off the samples can
// be compared against a frequency read off the log.
void sbref_mute(sbref_t *self, unsigned channel, bool muted)
{
    GB_set_channel_muted(&self->gb, (GB_channel_t)channel, muted);
}
