; The sound engine, on the SPC700.
;
; Metroid II's sound engine is bank 4 of the Game Boy ROM. This is that engine
; rewritten for the SPC700, plugged into the GB APU shim: every register write
; it makes is a call into the shim's register file, and the shim turns the
; Game Boy's APU units into S-DSP voices. See `.local/docs/2026-09-16-metroid2-
; audio/` in snes_game_dev for the cycle this belongs to, and `audio/shim/` for
; the package this assembles against.
;
; **What is ported, as of Step 7 (the gate): the song player.** `handleAudio`'s
; frame path, `handleSong`, `loadSongHeader`, `handleSongPlaying`, the
; instruction reader (`loadNextSound`) with its five instructions, the four
; per-channel `loadNextChannelSound` routines, and the pitch effects. Step 13
; added the square channels' sound effects, Step 14 the noise and wave
; channels', and Step 15 the song interruptions, the fade and the pause, which
; is all of bank 4 but `initializeAudio`'s own entry (that is `init` below).
;
; **Why the whole player and not square 1 alone.** Step 7 grades square 1's
; registers only, but three pieces of state the square-1 stream depends on are
; *shared* with the other three channels: `songTranspose` and
; `songInstructionTimerArrayPointer` are set by instructions $F3 and $F2 from
; whichever channel's stream reaches them, and `songSoundChannelEffectTimer` is
; one timer for all four. A port that ran square 1 alone would drift from the
; Game Boy the first time square 2 changed the tempo, so all four channels are
; here and the *comparison* is what narrows to square 1.
;
; **The transcription's shape.** The Game Boy's audio RAM ($CEC0-$CFFF) is
; mirrored byte for byte into engine RAM at the same relative offsets, and
; every variable below is named for the Game Boy address it stands at. That
; makes each routine here readable beside M2RoS `src/bank_004.asm`, which is
; the only way a port this size can be checked by eye as well as by grade. The
; `V__` prefix marks a mirrored Game Boy variable; lower-case names are this
; port's own scratch, on the direct page the shim reserves for an engine.
;
; **Flags.** The SM83 and the SPC700 disagree about carry on a compare: after
; `cmp A, #n` the SPC700 sets C when A >= n, where the SM83's `cp n` sets it
; when A < n. So SM83 `jr c` is `bcc` here and `jr nc` is `bcs`, which is the
; single easiest thing in this file to get backwards.
;
; The ABI it expects is asserted below rather than assumed. `audio/shim/` is a
; synced copy of another repository's build product, and the failure it could
; otherwise cause -- a jump table that moved under an engine assembled against
; the old one -- is silent on the SPC700 and would show up as noise.

.include "../../audio/shim/shim_abi.inc"
.include "aram_data.inc"

; The shim ABI this source is written against. `zig build verify` compares it
; with `audio/shim/MANIFEST`'s `abi` line without needing an assembler, and the
; assembler compares it with the header the package actually carries.
    SHIM_ABI_EXPECTED = 3

.codebank ENGINE_CODE_ADDR..ENGINE_CODE_END
.varbank enginepage ENGINE_DP_ADDR..ENGINE_DP_END

; The reply the 65816 reads back each frame. The first five are the engine
; variables the game itself reads (surveyed in `02-plan.md`, Step 16b): six
; sites read `songPlaying`, two `sfxPlaying_square1`, one each
; `sfxPlaying_noise` and `sfxPlaying_lowHealthBeep`, three
; `songInterruptionPlaying`. They are named here from the start so that the
; port's layout is fixed before anything fills it.
    REPLY_SONG_PLAYING        = ENGINE_REPLY_ADDR + 0
    REPLY_SFX_SQUARE1_PLAYING = ENGINE_REPLY_ADDR + 1
    REPLY_SFX_NOISE_PLAYING   = ENGINE_REPLY_ADDR + 2
    REPLY_LOW_HEALTH_BEEP     = ENGINE_REPLY_ADDR + 3
    REPLY_SONG_INTERRUPTION   = ENGINE_REPLY_ADDR + 4
; The sixth is ours: the shim's version, written once at init. Nonzero means an
; engine ran `init`, which is the one thing a cart with no sound cannot tell
; from a boot that never finished.
    REPLY_ALIVE               = ENGINE_REPLY_ADDR + 5
    .assert ENGINE_REPLY_SIZE == 6


; The record the 65816 sends per tick: `(slot, value)` pairs, one for each
; request byte or engine variable the game had in force at that `handleAudio`
; call. The shim carries the bytes and reads only the length; what a slot means
; is settled here.
;
; The numbers are the Game Boy WRAM order of the bytes they stand for, which is
; a stated order rather than a chosen one -- a reader can check it against
; M2RoS `ram/wram.asm` without trusting this comment. Slots 0-5, 7 and 8 are
; the bytes that file's own header says the game "requests by writing directly
; to"; slot 6 is the one engine variable the game writes rather than reads
; (M2RoS `bank_001.asm:4057`), so it is a set-variable op and not a request.
;
; `src/audio_req.zig` reads these equates out of this file, the way
; `src/audio_shim.zig` reads `SHIM_ABI_EXPECTED`, so the comparison harness and
; the engine cannot disagree about what a slot number means.
    REQ_SFX_SQUARE1           = 0   ; $CEC0 sfxRequest_square1
    REQ_SFX_SQUARE2           = 1   ; $CEC7 sfxRequest_square2
    REQ_SFX_FAKE_WAVE         = 2   ; $CECE sfxRequest_fakeWave
    REQ_SFX_NOISE             = 3   ; $CED5 sfxRequest_noise
    REQ_SONG                  = 4   ; $CEDC songRequest
    REQ_SONG_INTERRUPTION     = 5   ; $CEDE songInterruptionRequest
    REQ_SET_SONG_INT_PLAYING  = 6   ; $CEDF songInterruptionPlaying (set, not request)
    REQ_PAUSE_CONTROL         = 7   ; $CFC7 audioPauseControl
    REQ_SFX_WAVE              = 8   ; $CFE5 sfxRequest_wave
; Slots 9 and 10 are game state, not audio RAM: two bytes the engine reads and
; the game owns. `maybeResumeScrewAttackingSfx` (M2RoS bank_004.asm:3528) asks
; whether Samus is still spin-jumping with the screw attack when an energy-drop
; sound ends. On the Game Boy it reads them straight out of WRAM; here the
; 65816 has to send them, and it sends them in the record like everything else
; so that one mechanism carries all the engine's input. They are not cleared
; after a tick, because the Game Boy does not clear them either.
    REQ_SAMUS_POSE            = 9   ; $D020 samusPose
    REQ_SAMUS_ITEMS           = 10  ; $D045 samusItems
; Slot 11 is the Game Boy's divider, rDIV ($FF04). Five cries seed a pitch from
; it (square 1's $1B, square 2's $03-$06), and noise $05, $09, $0A, $16 and $17
; request them, so the slice's Metroid-hurt sound reaches one. The SPC700 has
; no such counter; the 65816 sends a byte instead, and it holds until sent again.
    REQ_DIV                   = 11  ; $FF04 rDIV
; Slot 12 is not a byte: it is the game calling `silenceAudio` (M2RoS
; bank_004.asm:1049) outside `handleAudio`, at a death, the boot and two unused
; game modes. It runs where it stands in the record, so a request before it is
; cleared and one after it survives, and its value is not read.
    REQ_CALL_SILENCE_AUDIO    = 12  ; 4:$4003 externalSilenceAudio
    REQ_SLOT_COUNT            = 13


; ---------------------------------------------------------------------------
; The Game Boy's audio RAM, mirrored
; ---------------------------------------------------------------------------
;
; `V__x = GBRAM_BASE + $XXXX - GBRAM_ORG` for the Game Boy address $XXXX, so
; every line below carries the address a reader checks against M2RoS
; `src/ram/wram.asm`, and the mirror keeps the engine's own layout -- including
; the "$CF10..CF23's low bytes match $FF10..23" coincidence the Game Boy code
; exploits -- without anybody having to restate it.
    GBRAM_ORG  = $CE00
    GBRAM_BASE = ENGINE_RAM_ADDR + $100

; The engine's own state, which the Game Boy has no counterpart for. It sits
; below the mirror so the mirror's arithmetic stays exact.
    ENGINE_VARS = ENGINE_RAM_ADDR + ENGINE_REPLY_SIZE

; NR51, shadowed. The Game Boy reads the register back to set bits 6 and 2 on a
; wave note (`loadNextSound`); `shim_write_reg` only writes, so the engine has
; to remember what it last put there. Every NR51 write in this file goes
; through this byte, which is what makes the shadow exact rather than hopeful.
    ram_nr51 = ENGINE_VARS + 0

; The game state slots 9 and 10 write (see REQ_SAMUS_POSE). They sit with the
; engine's own variables rather than in the mirror, because the mirror is audio
; RAM and `initializeAudio` clears it; these are not the engine's to clear.
    game_samusPose  = ENGINE_VARS + 1
    game_samusItems = ENGINE_VARS + 2

; What this engine reads where the Game Boy reads rDIV, the free-running
; divider: slot 11's byte (REQ_DIV). Not in the mirror, for the same reason as
; the game state above.
    ram_div = ENGINE_VARS + 3

    V__sfxRequest_square1      = GBRAM_BASE + $CEC0 - GBRAM_ORG
    V__sfxPlaying_square1      = GBRAM_BASE + $CEC1 - GBRAM_ORG
    V__sfxTimer_square1        = GBRAM_BASE + $CEC3 - GBRAM_ORG
    V__samusHealthChangedOptionSetIndex = GBRAM_BASE + $CEC4 - GBRAM_ORG
    V__sfxRequest_square2      = GBRAM_BASE + $CEC7 - GBRAM_ORG
    V__sfxPlaying_square2      = GBRAM_BASE + $CEC8 - GBRAM_ORG
    V__sfxTimer_square2        = GBRAM_BASE + $CECA - GBRAM_ORG
    V__square2_variableFrequency = GBRAM_BASE + $CECC - GBRAM_ORG
    V__sfxRequest_fakeWave     = GBRAM_BASE + $CECE - GBRAM_ORG
    V__sfxPlaying_fakeWave     = GBRAM_BASE + $CECF - GBRAM_ORG
    V__sfxRequest_noise        = GBRAM_BASE + $CED5 - GBRAM_ORG
    V__sfxPlaying_noise        = GBRAM_BASE + $CED6 - GBRAM_ORG
    V__sfxTimer_noise          = GBRAM_BASE + $CED8 - GBRAM_ORG
    V__songRequest             = GBRAM_BASE + $CEDC - GBRAM_ORG
    V__songPlaying             = GBRAM_BASE + $CEDD - GBRAM_ORG
    V__songInterruptionRequest = GBRAM_BASE + $CEDE - GBRAM_ORG
    V__songInterruptionPlaying = GBRAM_BASE + $CEDF - GBRAM_ORG
    V__sfxActive_square1       = GBRAM_BASE + $CEE4 - GBRAM_ORG
    V__sfxActive_square2       = GBRAM_BASE + $CEE5 - GBRAM_ORG
    V__sfxActive_wave          = GBRAM_BASE + $CEE6 - GBRAM_ORG
    V__sfxActive_noise         = GBRAM_BASE + $CEE7 - GBRAM_ORG
    V__resumeScrewAttackSoundEffectFlag = GBRAM_BASE + $CEE8 - GBRAM_ORG

    V__songTranspose           = GBRAM_BASE + $CF00 - GBRAM_ORG
    V__timerArrayPointer       = GBRAM_BASE + $CF01 - GBRAM_ORG ; big-endian(!)
    V__workingSoundChannel     = GBRAM_BASE + $CF03 - GBRAM_ORG
    V__songChannelEnable_square1 = GBRAM_BASE + $CF04 - GBRAM_ORG
    V__songChannelEnable_square2 = GBRAM_BASE + $CF05 - GBRAM_ORG
    V__songChannelEnable_wave    = GBRAM_BASE + $CF06 - GBRAM_ORG
    V__songChannelEnable_noise   = GBRAM_BASE + $CF07 - GBRAM_ORG
    V__songOptionsSetFlag_working = GBRAM_BASE + $CF08 - GBRAM_ORG
    V__songWavePatternDataPointer = GBRAM_BASE + $CF09 - GBRAM_ORG

; The working channel's options, $CF0B..$CF0F. Two names apiece where the Game
; Boy has two: the sweep byte is the wave channel's enable, the envelope byte
; is its volume, and the frequency's two bytes are the noise channel's
; polynomial counter and counter control.
    V__songSweep_working       = GBRAM_BASE + $CF0B - GBRAM_ORG
    V__songEnable_working      = GBRAM_BASE + $CF0B - GBRAM_ORG
    V__songSoundLength_working = GBRAM_BASE + $CF0C - GBRAM_ORG
    V__songEnvelope_working    = GBRAM_BASE + $CF0D - GBRAM_ORG
    V__songVolume_working      = GBRAM_BASE + $CF0D - GBRAM_ORG
    V__songFrequency_working   = GBRAM_BASE + $CF0E - GBRAM_ORG
    V__songPolyCounter_working = GBRAM_BASE + $CF0E - GBRAM_ORG
    V__songCounterControl_working = GBRAM_BASE + $CF0F - GBRAM_ORG

; The per-channel options, $CF10..$CF23.
    V__songSweep_square1       = GBRAM_BASE + $CF10 - GBRAM_ORG
    V__songSoundLength_square1 = GBRAM_BASE + $CF11 - GBRAM_ORG
    V__songEnvelope_square1    = GBRAM_BASE + $CF12 - GBRAM_ORG
    V__songFrequency_square1   = GBRAM_BASE + $CF13 - GBRAM_ORG
    V__songSoundLength_square2 = GBRAM_BASE + $CF16 - GBRAM_ORG
    V__songEnvelope_square2    = GBRAM_BASE + $CF17 - GBRAM_ORG
    V__songFrequency_square2   = GBRAM_BASE + $CF18 - GBRAM_ORG
    V__songEnableOption_wave   = GBRAM_BASE + $CF1A - GBRAM_ORG
    V__songSoundLength_wave    = GBRAM_BASE + $CF1B - GBRAM_ORG
    V__songVolume_wave         = GBRAM_BASE + $CF1C - GBRAM_ORG
    V__songFrequency_wave      = GBRAM_BASE + $CF1D - GBRAM_ORG
    V__songSoundLength_noise   = GBRAM_BASE + $CF20 - GBRAM_ORG
    V__songEnvelope_noise      = GBRAM_BASE + $CF21 - GBRAM_ORG
    V__songPolyCounter_noise   = GBRAM_BASE + $CF22 - GBRAM_ORG
    V__songCounterControl_noise = GBRAM_BASE + $CF23 - GBRAM_ORG

; The instruction pointers, $CF26..$CF2D. Big-endian, like every pointer the
; Game Boy engine keeps in RAM: the high byte is at +0.
    V__insPtr_square1          = GBRAM_BASE + $CF26 - GBRAM_ORG
    V__insPtr_square2          = GBRAM_BASE + $CF28 - GBRAM_ORG
    V__insPtr_wave             = GBRAM_BASE + $CF2A - GBRAM_ORG
    V__insPtr_noise            = GBRAM_BASE + $CF2C - GBRAM_ORG

    V__songSoundChannelEffectTimer = GBRAM_BASE + $CF2E - GBRAM_ORG

; The five song processing state blocks, $CF2F..$CF5B, nine bytes each. The
; offsets are the block's fields, so `V__state_square1 + STATE__instructionTimer`
; is `songInstructionTimer_square1` without a second address to keep in step.
    V__songProcessingStates    = GBRAM_BASE + $CF2F - GBRAM_ORG
    V__state_working           = GBRAM_BASE + $CF2F - GBRAM_ORG
    V__state_square1           = GBRAM_BASE + $CF38 - GBRAM_ORG
    V__state_square2           = GBRAM_BASE + $CF41 - GBRAM_ORG
    V__state_wave              = GBRAM_BASE + $CF4A - GBRAM_ORG
    V__state_noise             = GBRAM_BASE + $CF53 - GBRAM_ORG

    STATE__sectionPointer      = 0 ; 2 bytes, big-endian
    STATE__repeatCount         = 2 ; 2 bytes, big-endian (a saved position)
    STATE__repeatPoint         = 4
    STATE__instructionLength   = 5
    STATE__noteEnvelope        = 6 ; the wave channel's note volume
    STATE__instructionTimer    = 7
    STATE__effectIndex         = 8 ; the noise channel's sound length

    V__songFadeoutTimer        = GBRAM_BASE + $CF5C - GBRAM_ORG
    V__ramCF5D                 = GBRAM_BASE + $CF5D - GBRAM_ORG ; written by the fade, never read
    V__ramCF5E                 = GBRAM_BASE + $CF5E - GBRAM_ORG
    V__ramCF5F                 = GBRAM_BASE + $CF5F - GBRAM_ORG
    V__songFrequencyTweak_square2 = GBRAM_BASE + $CF60 - GBRAM_ORG

; `songProcessingState` is $CF00..$CF60, and a song interruption copies it whole
; to $CF61..$CFC1 and back. The length is the ROM's byte, not a constant here
; (`DATA__stateSizes + 2`, M2RoS bank_004.asm:25).
    V__songProcessingState     = GBRAM_BASE + $CF00 - GBRAM_ORG
    V__songProcessingStateBackup = GBRAM_BASE + $CF61 - GBRAM_ORG
    V__songPlayingBackup       = GBRAM_BASE + $CFC5 - GBRAM_ORG
    V__songSweepBackup_square1 = GBRAM_BASE + $CFC9 - GBRAM_ORG
    V__audioPauseControl       = GBRAM_BASE + $CFC7 - GBRAM_ORG
    V__audioPauseSfxTimer      = GBRAM_BASE + $CFC8 - GBRAM_ORG
    V__sfxVariableFrequency_square1 = GBRAM_BASE + $CFD1 - GBRAM_ORG
    V__ramCFE3                 = GBRAM_BASE + $CFE3 - GBRAM_ORG
    V__sfxRequest_wave         = GBRAM_BASE + $CFE5 - GBRAM_ORG
    V__sfxRequest_lowHealthBeep = GBRAM_BASE + $CFE5 - GBRAM_ORG
    V__sfxPlaying_wave         = GBRAM_BASE + $CFE6 - GBRAM_ORG
    V__sfxPlaying_lowHealthBeep = GBRAM_BASE + $CFE6 - GBRAM_ORG
    V__sfxPlayingBackup_lowHealthBeep = GBRAM_BASE + $CFE7 - GBRAM_ORG
    V__sfxTimer_wave          = GBRAM_BASE + $CFE8 - GBRAM_ORG
    V__sfxLength_wave          = GBRAM_BASE + $CFE9 - GBRAM_ORG
    V__ramCFEB                 = GBRAM_BASE + $CFEB - GBRAM_ORG ; cleared, never read
    V__stereoFlags             = GBRAM_BASE + $CFEC - GBRAM_ORG
    V__stereoFlagsBackup       = GBRAM_BASE + $CFED - GBRAM_ORG
    V__loudLowHealthBeepTimer  = GBRAM_BASE + $CFEE - GBRAM_ORG

; What `initializeAudio` clears, and the span the mirror has to hold.
    GBRAM_CLEAR_FIRST = GBRAM_BASE + $CEC0 - GBRAM_ORG
    GBRAM_CLEAR_END   = GBRAM_BASE + $D000 - GBRAM_ORG

; The song interruption ids and song ids this file compares against (M2RoS
; `ram/wram.asm`).
    SONGINT__ITEM_GET        = 1
    SONGINT__END_PLAYING     = 2
    SONGINT__END_REQUEST     = 3
    SONGINT__MISSILE_PICKUP  = 5
    SONGINT__FADE_OUT        = 8
    SONGINT__EARTHQUAKE      = $0E
    SONGINT__CLEAR           = $FF

    SONG__CHOZO_RUINS        = $03
    SONG__ITEM_GET           = $0A
    SONG__MISSILE_PICKUP     = $20
    SONG__EARTHQUAKE         = $0E
    SONG__KILLED_METROID     = $0F

; Square 1's sound effect ids this file compares against, the Game Boy's pose
; for a spin jump and the screw attack's item bit (M2RoS `ram/wram.asm`,
; `samus/samus_poseConstants.asm`, `constants.asm`).
    SFX_SQ1__SCREW_ATTACKING      = $03
    SFX_SQ1__STANDING_TRANSITION  = $04
    SFX_SQ1__SHOOTING_BEAM        = $07
    SFX_SQ1__SHOOTING_SPAZER_BEAM = $0B
    SFX_SQ1__PICKED_UP_MISSILE_DROP = $0C
    SFX_SQ1__SHOOTING_WAVE_BEAM   = $16
    SFX_SQ1__SAMUS_HEALTH_CHANGE  = $18
    SFX_SQ1__END                  = $1F     ; the first id past the table
    SFX_SQ1__METROID_CRY          = $1B
    SFX_SQ2__END                  = $08
    SFX_SQ2__METROID_QUEEN_CRY    = $03
    SFX_SQ2__BABY_METROID_CLEARING_BLOCK = $04
    SFX_SQ2__BABY_METROID_CRY     = $05
    SFX_SQ2__METROID_QUEEN_HURT_CRY = $06

; The noise and wave channels' (M2RoS `ram/wram.asm`): the three noise effects
; no other noise request can cut off, and the first id past each table.
    SFX_NOISE__METROID_KILLED     = $0D
    SFX_NOISE__OMEGA_METROID_EXPLOSION = $0E
    SFX_NOISE__CLEARED_SAVE_FILE  = $0F
    SFX_NOISE__END                = $1B
    SFX_WAVE__END                 = $06

    POSE__SPIN_JUMP          = $02
    ITEM_BIT__SCREW          = 2

    PAUSE__PAUSE             = 1
    PAUSE__UNPAUSE           = 2

; The five effect tables are one 80-byte block, in index order, and the timer
; that indexes them counts $10 down from $11 -- so table N's index $10 is table
; N+1's first byte. That overrun is the Game Boy's behaviour (M2RoS calls it a
; bug), and it stays faithful only because the tables are contiguous here too.
    EFFECT_TABLE_STRIDE = $10
    DATA__effectTable_index2 = DATA__songEffectTables + 0 * EFFECT_TABLE_STRIDE
    DATA__effectTable_index3 = DATA__songEffectTables + 1 * EFFECT_TABLE_STRIDE
    DATA__effectTable_index4 = DATA__songEffectTables + 2 * EFFECT_TABLE_STRIDE
    DATA__effectTable_index9 = DATA__songEffectTables + 3 * EFFECT_TABLE_STRIDE
    DATA__effectTable_indexA = DATA__songEffectTables + 4 * EFFECT_TABLE_STRIDE

; The square channels' sound effect option sets, by name. Square 1's are five
; bytes each (NR10-NR14) and square 2's four (NR21-NR24); the sound effect
; routines address them one at a time, so each gets the name M2RoS gives it and
; the Game Boy address it has there, relative to its block's first set. A wrong
; address here is a wrong register write at the first tick that uses it, which
; is what `test/audio/sfx/` grades: every id, so every set a routine can reach.
    OPT_SQ1__jumping_0 = DATA__optionSets_square1 + $5A28 - $5A28
    OPT_SQ1__jumping_1 = DATA__optionSets_square1 + $5A2D - $5A28
    OPT_SQ1__jumping_2 = DATA__optionSets_square1 + $5A32 - $5A28
    OPT_SQ1__jumping_3 = DATA__optionSets_square1 + $5A37 - $5A28
    OPT_SQ1__jumping_4 = DATA__optionSets_square1 + $5A3C - $5A28
    OPT_SQ1__jumping_5 = DATA__optionSets_square1 + $5A41 - $5A28
    OPT_SQ1__hijumping_0 = DATA__optionSets_square1 + $5A46 - $5A28
    OPT_SQ1__hijumping_1 = DATA__optionSets_square1 + $5A4B - $5A28
    OPT_SQ1__hijumping_2 = DATA__optionSets_square1 + $5A50 - $5A28
    OPT_SQ1__hijumping_3 = DATA__optionSets_square1 + $5A55 - $5A28
    OPT_SQ1__hijumping_4 = DATA__optionSets_square1 + $5A5A - $5A28
    OPT_SQ1__hijumping_5 = DATA__optionSets_square1 + $5A5F - $5A28
    OPT_SQ1__hijumping_6 = DATA__optionSets_square1 + $5A64 - $5A28
    OPT_SQ1__hijumping_7 = DATA__optionSets_square1 + $5A69 - $5A28
    OPT_SQ1__screwAttacking_0 = DATA__optionSets_square1 + $5A6E - $5A28
    OPT_SQ1__screwAttacking_1 = DATA__optionSets_square1 + $5A73 - $5A28
    OPT_SQ1__screwAttacking_2 = DATA__optionSets_square1 + $5A78 - $5A28
    OPT_SQ1__screwAttacking_3 = DATA__optionSets_square1 + $5A7D - $5A28
    OPT_SQ1__screwAttacking_4 = DATA__optionSets_square1 + $5A82 - $5A28
    OPT_SQ1__screwAttacking_5 = DATA__optionSets_square1 + $5A87 - $5A28
    OPT_SQ1__screwAttacking_6 = DATA__optionSets_square1 + $5A8C - $5A28
    OPT_SQ1__screwAttacking_7 = DATA__optionSets_square1 + $5A91 - $5A28
    OPT_SQ1__screwAttacking_8 = DATA__optionSets_square1 + $5A96 - $5A28
    OPT_SQ1__screwAttacking_9 = DATA__optionSets_square1 + $5A9B - $5A28
    OPT_SQ1__screwAttacking_A = DATA__optionSets_square1 + $5AA0 - $5A28
    OPT_SQ1__screwAttacking_B = DATA__optionSets_square1 + $5AA5 - $5A28
    OPT_SQ1__screwAttacking_C = DATA__optionSets_square1 + $5AAA - $5A28
    OPT_SQ1__screwAttacking_D = DATA__optionSets_square1 + $5AAF - $5A28
    OPT_SQ1__standingTransition_0 = DATA__optionSets_square1 + $5AB4 - $5A28
    OPT_SQ1__standingTransition_1 = DATA__optionSets_square1 + $5AB9 - $5A28
    OPT_SQ1__standingTransition_2 = DATA__optionSets_square1 + $5ABE - $5A28
    OPT_SQ1__crouchingTransition_0 = DATA__optionSets_square1 + $5AC3 - $5A28
    OPT_SQ1__crouchingTransition_1 = DATA__optionSets_square1 + $5AC8 - $5A28
    OPT_SQ1__crouchingTransition_2 = DATA__optionSets_square1 + $5ACD - $5A28
    OPT_SQ1__morphing_0 = DATA__optionSets_square1 + $5AD2 - $5A28
    OPT_SQ1__morphing_1 = DATA__optionSets_square1 + $5AD7 - $5A28
    OPT_SQ1__morphing_2 = DATA__optionSets_square1 + $5ADC - $5A28
    OPT_SQ1__shootingBeam_0 = DATA__optionSets_square1 + $5AE1 - $5A28
    OPT_SQ1__shootingBeam_1 = DATA__optionSets_square1 + $5AE6 - $5A28
    OPT_SQ1__shootingBeam_2 = DATA__optionSets_square1 + $5AEB - $5A28
    OPT_SQ1__shootingBeam_3 = DATA__optionSets_square1 + $5AF0 - $5A28
    OPT_SQ1__shootingBeam_4 = DATA__optionSets_square1 + $5AF5 - $5A28
    OPT_SQ1__shootingMissile_0 = DATA__optionSets_square1 + $5AFA - $5A28
    OPT_SQ1__shootingMissile_1 = DATA__optionSets_square1 + $5AFF - $5A28
    OPT_SQ1__shootingMissile_2 = DATA__optionSets_square1 + $5B04 - $5A28
    OPT_SQ1__shootingMissile_3 = DATA__optionSets_square1 + $5B09 - $5A28
    OPT_SQ1__shootingMissile_4 = DATA__optionSets_square1 + $5B0E - $5A28
    OPT_SQ1__shootingMissile_5 = DATA__optionSets_square1 + $5B13 - $5A28
    OPT_SQ1__shootingMissile_6 = DATA__optionSets_square1 + $5B18 - $5A28
    OPT_SQ1__shootingMissile_7 = DATA__optionSets_square1 + $5B1D - $5A28
    OPT_SQ1__shootingMissile_8 = DATA__optionSets_square1 + $5B22 - $5A28
    OPT_SQ1__shootingMissile_9 = DATA__optionSets_square1 + $5B27 - $5A28
    OPT_SQ1__shootingIceBeam = DATA__optionSets_square1 + $5B2C - $5A28
    OPT_SQ1__shootingPlasmaBeam = DATA__optionSets_square1 + $5B31 - $5A28
    OPT_SQ1__shootingSpazerBeam = DATA__optionSets_square1 + $5B36 - $5A28
    OPT_SQ1__pickingUpMissileDrop_0 = DATA__optionSets_square1 + $5B3B - $5A28
    OPT_SQ1__pickingUpMissileDrop_1 = DATA__optionSets_square1 + $5B40 - $5A28
    OPT_SQ1__pickingUpMissileDrop_2 = DATA__optionSets_square1 + $5B45 - $5A28
    OPT_SQ1__pickingUpMissileDrop_3 = DATA__optionSets_square1 + $5B4A - $5A28
    OPT_SQ1__pickingUpMissileDrop_4 = DATA__optionSets_square1 + $5B4F - $5A28
    OPT_SQ1__spiderBall_0 = DATA__optionSets_square1 + $5B54 - $5A28
    OPT_SQ1__spiderBall_1 = DATA__optionSets_square1 + $5B59 - $5A28
    OPT_SQ1__smallEnergyDrop_0 = DATA__optionSets_square1 + $5B5E - $5A28
    OPT_SQ1__smallEnergyDrop_1 = DATA__optionSets_square1 + $5B63 - $5A28
    OPT_SQ1__smallEnergyDrop_2 = DATA__optionSets_square1 + $5B68 - $5A28
    OPT_SQ1__pickedUpDropEnd = DATA__optionSets_square1 + $5B6D - $5A28
    OPT_SQ1__shotMissileDoorWithBeam_0 = DATA__optionSets_square1 + $5B72 - $5A28
    OPT_SQ1__shotMissileDoorWithBeam_1 = DATA__optionSets_square1 + $5B77 - $5A28
    OPT_SQ1__missileDoorExploding_0 = DATA__optionSets_square1 + $5B7C - $5A28
    OPT_SQ1__missileDoorExploding_1 = DATA__optionSets_square1 + $5B81 - $5A28
    OPT_SQ1__missileDoorExploding_2 = DATA__optionSets_square1 + $5B86 - $5A28
    OPT_SQ1__missileDoorExploding_3 = DATA__optionSets_square1 + $5B8B - $5A28
    OPT_SQ1__missileDoorExploding_4 = DATA__optionSets_square1 + $5B90 - $5A28
    OPT_SQ1__missileDoorExploding_5 = DATA__optionSets_square1 + $5B95 - $5A28
    OPT_SQ1__missileDoorExploding_6 = DATA__optionSets_square1 + $5B9A - $5A28
    OPT_SQ1__missileDoorExploding_7 = DATA__optionSets_square1 + $5B9F - $5A28
    OPT_SQ1__missileDoorExploding_8 = DATA__optionSets_square1 + $5BA4 - $5A28
    OPT_SQ1__missileDoorExploding_9 = DATA__optionSets_square1 + $5BA9 - $5A28
    OPT_SQ1__missileDoorExploding_A = DATA__optionSets_square1 + $5BAE - $5A28
    OPT_SQ1__unused12 = DATA__optionSets_square1 + $5BB3 - $5A28
    OPT_SQ1__bombLaid = DATA__optionSets_square1 + $5BB8 - $5A28
    OPT_SQ1__pipeBugSpawnerStop_0 = DATA__optionSets_square1 + $5BBD - $5A28
    OPT_SQ1__pipeBugSpawnerStop_1 = DATA__optionSets_square1 + $5BC2 - $5A28
    OPT_SQ1__optionMissileSelect_0 = DATA__optionSets_square1 + $5BC7 - $5A28
    OPT_SQ1__optionMissileSelect_1 = DATA__optionSets_square1 + $5BCC - $5A28
    OPT_SQ1__shootingWaveBeam_0 = DATA__optionSets_square1 + $5BD1 - $5A28
    OPT_SQ1__shootingWaveBeam_1 = DATA__optionSets_square1 + $5BD6 - $5A28
    OPT_SQ1__shootingWaveBeam_2 = DATA__optionSets_square1 + $5BDB - $5A28
    OPT_SQ1__shootingWaveBeam_3 = DATA__optionSets_square1 + $5BE0 - $5A28
    OPT_SQ1__shootingWaveBeam_4 = DATA__optionSets_square1 + $5BE5 - $5A28
    OPT_SQ1__largeEnergyDrop_0 = DATA__optionSets_square1 + $5BEA - $5A28
    OPT_SQ1__largeEnergyDrop_1 = DATA__optionSets_square1 + $5BEF - $5A28
    OPT_SQ1__largeEnergyDrop_2 = DATA__optionSets_square1 + $5BF4 - $5A28
    OPT_SQ1__largeEnergyDrop_3 = DATA__optionSets_square1 + $5BF9 - $5A28
    OPT_SQ1__largeEnergyDrop_4 = DATA__optionSets_square1 + $5BFE - $5A28
    OPT_SQ1__samusHealthChanged_0 = DATA__optionSets_square1 + $5C03 - $5A28
    OPT_SQ1__samusHealthChanged_1 = DATA__optionSets_square1 + $5C08 - $5A28
    OPT_SQ1__noMissileDudShot_0 = DATA__optionSets_square1 + $5C0D - $5A28
    OPT_SQ1__noMissileDudShot_1 = DATA__optionSets_square1 + $5C12 - $5A28
    OPT_SQ1__metroidScrewAttacked_0 = DATA__optionSets_square1 + $5C17 - $5A28
    OPT_SQ1__metroidScrewAttacked_1 = DATA__optionSets_square1 + $5C1C - $5A28
    OPT_SQ1__metroidScrewAttacked_2 = DATA__optionSets_square1 + $5C21 - $5A28
    OPT_SQ1__metroidScrewAttacked_3 = DATA__optionSets_square1 + $5C26 - $5A28
    OPT_SQ1__metroidScrewAttacked_4 = DATA__optionSets_square1 + $5C2B - $5A28
    OPT_SQ1__metroidScrewAttacked_5 = DATA__optionSets_square1 + $5C30 - $5A28
    OPT_SQ1__metroidScrewAttacked_6 = DATA__optionSets_square1 + $5C35 - $5A28
    OPT_SQ1__metroidCry = DATA__optionSets_square1 + $5C3A - $5A28
    OPT_SQ1__saved0 = DATA__optionSets_square1 + $5C3F - $5A28
    OPT_SQ1__saved1 = DATA__optionSets_square1 + $5C44 - $5A28
    OPT_SQ1__saved2 = DATA__optionSets_square1 + $5C49 - $5A28
    OPT_SQ1__variaSuitTransformation = DATA__optionSets_square1 + $5C4E - $5A28
    OPT_SQ1__unpaused_0 = DATA__optionSets_square1 + $5C53 - $5A28
    OPT_SQ1__unpaused_1 = DATA__optionSets_square1 + $5C58 - $5A28
    OPT_SQ1__unpaused_2 = DATA__optionSets_square1 + $5C5D - $5A28
    OPT_SQ1__exampleA = DATA__optionSets_square1 + $5C62 - $5A28
    OPT_SQ1__exampleB = DATA__optionSets_square1 + $5C67 - $5A28
    OPT_SQ1__exampleC = DATA__optionSets_square1 + $5C6C - $5A28
    OPT_SQ1__exampleD = DATA__optionSets_square1 + $5C71 - $5A28
    OPT_SQ1__exampleE = DATA__optionSets_square1 + $5C76 - $5A28
    OPT_SQ2__metroidQueenCry = DATA__optionSets_square2 + $5D2B - $5D2B
    OPT_SQ2__babyMetroidClearingBlock = DATA__optionSets_square2 + $5D2F - $5D2B
    OPT_SQ2__babyMetroidCry = DATA__optionSets_square2 + $5D33 - $5D2B
    OPT_SQ2__metroidQueenHurtCry = DATA__optionSets_square2 + $5D37 - $5D2B
    OPT_SQ2__automFlamethrower = DATA__optionSets_square2 + $5D3B - $5D2B
; The noise channel's, four bytes each (NR41-NR44), and the wave channel's,
; five (NR30-NR34), named the same way. `acidDamage_1` is `SamusHurt_1`: M2RoS
; gives the one set both names.
    OPT_NOISE__enemyShot = DATA__optionSets_noise + $5C7B - $5C7B
    OPT_NOISE__enemyKilled_0 = DATA__optionSets_noise + $5C7F - $5C7B
    OPT_NOISE__enemyKilled_1 = DATA__optionSets_noise + $5C83 - $5C7B
    OPT_NOISE__enemyExplosion = DATA__optionSets_noise + $5C87 - $5C7B
    OPT_NOISE__shotBlockDestroyed = DATA__optionSets_noise + $5C8B - $5C7B
    OPT_NOISE__metroidHurt_0 = DATA__optionSets_noise + $5C8F - $5C7B
    OPT_NOISE__metroidHurt_1 = DATA__optionSets_noise + $5C93 - $5C7B
    OPT_NOISE__SamusHurt_0 = DATA__optionSets_noise + $5C97 - $5C7B
    OPT_NOISE__SamusHurt_1 = DATA__optionSets_noise + $5C9B - $5C7B
    OPT_NOISE__acidDamage_1 = DATA__optionSets_noise + $5C9B - $5C7B
    OPT_NOISE__acidDamage_0 = DATA__optionSets_noise + $5C9F - $5C7B
    OPT_NOISE__shotMissileDoor_0 = DATA__optionSets_noise + $5CA3 - $5C7B
    OPT_NOISE__shotMissileDoor_1 = DATA__optionSets_noise + $5CA7 - $5C7B
    OPT_NOISE__metroidQueenCry_0 = DATA__optionSets_noise + $5CAB - $5C7B
    OPT_NOISE__metroidQueenCry_1 = DATA__optionSets_noise + $5CAF - $5C7B
    OPT_NOISE__metroidQueenHurtCry_0 = DATA__optionSets_noise + $5CB3 - $5C7B
    OPT_NOISE__metroidQueenHurtCry_1 = DATA__optionSets_noise + $5CB7 - $5C7B
    OPT_NOISE__samusKilled_1 = DATA__optionSets_noise + $5CBB - $5C7B
    OPT_NOISE__samusKilled_2 = DATA__optionSets_noise + $5CBF - $5C7B
    OPT_NOISE__samusKilled_3 = DATA__optionSets_noise + $5CC3 - $5C7B
    OPT_NOISE__bombDetonated_0 = DATA__optionSets_noise + $5CC7 - $5C7B
    OPT_NOISE__bombDetonated_1 = DATA__optionSets_noise + $5CCB - $5C7B
    OPT_NOISE__metroidKilled_0 = DATA__optionSets_noise + $5CCF - $5C7B
    OPT_NOISE__metroidKilled_1 = DATA__optionSets_noise + $5CD3 - $5C7B
    OPT_NOISE__omegaMetroidExplosion_0 = DATA__optionSets_noise + $5CD7 - $5C7B
    OPT_NOISE__omegaMetroidExplosion_1 = DATA__optionSets_noise + $5CDB - $5C7B
    OPT_NOISE__clearedSaveFile_0 = DATA__optionSets_noise + $5CDF - $5C7B
    OPT_NOISE__clearedSaveFile_1 = DATA__optionSets_noise + $5CE3 - $5C7B
    OPT_NOISE__footsteps_0 = DATA__optionSets_noise + $5CE7 - $5C7B
    OPT_NOISE__footsteps_1 = DATA__optionSets_noise + $5CEB - $5C7B
    OPT_NOISE__enemyHitGround_0 = DATA__optionSets_noise + $5CEF - $5C7B
    OPT_NOISE__misc_11_12_13_1 = DATA__optionSets_noise + $5CF3 - $5C7B
    OPT_NOISE__enemyProjectileFired_0 = DATA__optionSets_noise + $5CF7 - $5C7B
    OPT_NOISE__autrackLaser_0 = DATA__optionSets_noise + $5CFB - $5C7B
    OPT_NOISE__gammaMetroidLightning_0 = DATA__optionSets_noise + $5CFF - $5C7B
    OPT_NOISE__gammaMetroidLightning_1 = DATA__optionSets_noise + $5D03 - $5C7B
    OPT_NOISE__metroidFireball_0 = DATA__optionSets_noise + $5D07 - $5C7B
    OPT_NOISE__metroidFireball_1 = DATA__optionSets_noise + $5D0B - $5C7B
    OPT_NOISE__babyMetroidClearingBlock = DATA__optionSets_noise + $5D0F - $5C7B
    OPT_NOISE__babyMetroidCry = DATA__optionSets_noise + $5D13 - $5C7B
    OPT_NOISE__autrackRises_0 = DATA__optionSets_noise + $5D17 - $5C7B
    OPT_NOISE__autrackRises_1 = DATA__optionSets_noise + $5D1B - $5C7B
    OPT_NOISE__noMissileDudShot = DATA__optionSets_noise + $5D1F - $5C7B
    OPT_NOISE__autoadJump = DATA__optionSets_noise + $5D23 - $5C7B
    OPT_NOISE__samusKilled_0 = DATA__optionSets_noise + $5D27 - $5C7B
    OPT_WAVE__healthUnder20_0 = DATA__optionSets_wave + $5EFF - $5EFF
    OPT_WAVE__healthUnder20_1 = DATA__optionSets_wave + $5F04 - $5EFF
    OPT_WAVE__healthUnder30_0 = DATA__optionSets_wave + $5F09 - $5EFF
    OPT_WAVE__healthUnder30_1 = DATA__optionSets_wave + $5F0E - $5EFF
    OPT_WAVE__healthUnder40_0 = DATA__optionSets_wave + $5F13 - $5EFF
    OPT_WAVE__healthUnder40_1 = DATA__optionSets_wave + $5F18 - $5EFF
    OPT_WAVE__healthUnder50_0 = DATA__optionSets_wave + $5F1D - $5EFF
    OPT_WAVE__healthUnder50_1 = DATA__optionSets_wave + $5F22 - $5EFF
; Every set in all four blocks is named, the unused `example` ones included, so
; that the last name plus its width landing exactly on the block's end checks
; the lot.
.assert OPT_SQ1__exampleE + 5 == DATA__optionSets_square1 + $253
.assert OPT_SQ2__automFlamethrower + 4 == DATA__optionSets_square2 + $14
.assert OPT_NOISE__samusKilled_0 + 4 == DATA__optionSets_noise + $B0
.assert OPT_WAVE__healthUnder50_1 + 5 == DATA__optionSets_wave + $28

; The two wave patterns the low-health beep alternates between, loud and quiet
; (M2RoS bank_004.asm:73, `wavePatterns`, from $4113).
    WAVE__wave4 = DATA__wavePatterns + $418B - $4113
    WAVE__wave5 = DATA__wavePatterns + $419B - $4113


; This port's own scratch, on the direct page the shim reserves for an engine.
; `hl`, `de` and `bc` stand for the SM83 register pairs of the same names, so
; the routines below read beside the originals; they are little-endian here,
; which is the SPC700's word order and not the Game Boy engine's RAM order.
.vars enginepage
    hl : ptr
    de : ptr
    bc : ptr
    tmp : ptr               ; a pointer the transcription needs and the SM83 did not
    hlsave : ptr            ; SM83 `push hl`; never nested, see each use
    asave : u8              ; SM83 `push af`, for the value only
    cnt : u8                ; SM83 `b` as a loop counter
    reclen : u8             ; the tick record's length
    recpos : u8             ; how far into it we are
    slot : u8
    val : u8
    regidx : u8             ; SM83 `hl` walking the registers in `setChannelOptionSet`
.endvars

; The mirror, the engine's own variables and the scratch page all have to fit
; what the shim gave the engine, and the scratch page has to be a direct page.
.assert GBRAM_CLEAR_END <= ENGINE_RAM_END
.assert GBRAM_CLEAR_FIRST >= ENGINE_VARS + 1
.assert GBRAM_CLEAR_END - GBRAM_CLEAR_FIRST == $140
.assert ENGINE_DP_END <= $0100
.assert DATA__songEffectTables + 5 * EFFECT_TABLE_STRIDE <= DATA__END


; The shim jumps here by address, so the two entries are first and in order.
.proc entry_points
    .assert SHIM_ABI_VERSION == SHIM_ABI_EXPECTED
    .assert PC == ENGINE__INIT
    jmp init
    .assert PC == ENGINE__TICK
    jmp tick
.endproc


; Called once, after the shim's own reset and before any tick.
;
; This is M2RoS `initializeAudio`, plus the reply. The three register writes are
; that routine's, in its order; the shim resets its trace after `init` returns,
; so they are not charged to tick 0, and the Game Boy harness likewise attaches
; its APU log after calling `initializeAudio`. What the two sides compare is
; ticks.
.proc init
    mov A, #$80
    mov X, #REG__NR52
    call SHIM_ENTRY__WRITE_REG
    mov A, #$77
    mov X, #REG__NR50
    call SHIM_ENTRY__WRITE_REG
    mov A, #$ff
    mov ram_nr51, A
    mov X, #REG__NR51
    call SHIM_ENTRY__WRITE_REG

    ; $CEC0..$CFFF, cleared. The Game Boy walks it with a 16-bit pointer; a
    ; page and a tail is the same 320 bytes and needs no pointer at all.
    mov A, #0
    mov Y, #0
ClearPage:
    mov GBRAM_CLEAR_FIRST+Y, A
    inc Y
    bne ClearPage
    mov X, #GBRAM_CLEAR_END - GBRAM_CLEAR_FIRST - $100
ClearTail:
    dec X
    mov GBRAM_CLEAR_FIRST+$100+X, A
    bne ClearTail

    mov REPLY_SONG_PLAYING, A
    mov REPLY_SFX_SQUARE1_PLAYING, A
    mov REPLY_SFX_NOISE_PLAYING, A
    mov REPLY_LOW_HEALTH_BEEP, A
    mov REPLY_SONG_INTERRUPTION, A
    call SHIM_ENTRY__VERSION
    mov REPLY_ALIVE, A
    ret
.endproc


; One `handleAudio` call. A = the record's length; HOSTED_RECORD_PTR points at
; its first byte, which is the requests the 65816 had in force at that call.
;
; The record is `(slot, value)` pairs. Each pair is a write to the Game Boy
; variable that slot stands for -- the same write the game's own code makes on
; the Game Boy -- so applying them all and then running `handleAudio` is what
; puts this engine in the state the other one is in.
.proc tick
    mov reclen, A
    mov recpos, #0

Apply:
    ; Two bytes at a time, and a trailing odd byte is not a pair: a malformed
    ; record ends the loop rather than reading past what the shim carried.
    mov A, recpos
    inc A
    cmp A, reclen
    bcs Done

    mov Y, recpos
    mov A, [HOSTED_RECORD_PTR]+Y
    mov slot, A
    inc Y
    mov A, [HOSTED_RECORD_PTR]+Y
    mov val, A
    inc Y
    mov recpos, Y

    mov A, slot
    cmp A, #REQ_CALL_SILENCE_AUDIO
    bne NotSilence
    call silenceAudio
    bra Apply
NotSilence:
    cmp A, #REQ_CALL_SILENCE_AUDIO
    bcs Apply               ; a slot this engine has no variable for
    asl A
    mov X, A
    mov A, SlotAddr+X
    mov tmp.l, A
    mov A, SlotAddr+1+X
    mov tmp.h, A
    mov A, val
    mov Y, #0
    mov [tmp]+Y, A
    bra Apply

Done:
    call handleAudio

    mov A, V__songPlaying
    mov REPLY_SONG_PLAYING, A
    mov A, V__sfxPlaying_square1
    mov REPLY_SFX_SQUARE1_PLAYING, A
    mov A, V__sfxPlaying_noise
    mov REPLY_SFX_NOISE_PLAYING, A
    mov A, V__sfxPlaying_lowHealthBeep
    mov REPLY_LOW_HEALTH_BEEP, A
    mov A, V__songInterruptionPlaying
    mov REPLY_SONG_INTERRUPTION, A
    ret

; Slot number to Game Boy variable, in `REQ_*` order.
SlotAddr:
    .dw V__sfxRequest_square1       ; REQ_SFX_SQUARE1
    .dw V__sfxRequest_square2       ; REQ_SFX_SQUARE2
    .dw V__sfxRequest_fakeWave      ; REQ_SFX_FAKE_WAVE
    .dw V__sfxRequest_noise         ; REQ_SFX_NOISE
    .dw V__songRequest              ; REQ_SONG
    .dw V__songInterruptionRequest  ; REQ_SONG_INTERRUPTION
    .dw V__songInterruptionPlaying  ; REQ_SET_SONG_INT_PLAYING
    .dw V__audioPauseControl        ; REQ_PAUSE_CONTROL
    .dw V__sfxRequest_wave          ; REQ_SFX_WAVE
    .dw game_samusPose              ; REQ_SAMUS_POSE
    .dw game_samusItems             ; REQ_SAMUS_ITEMS
    .dw ram_div                     ; REQ_DIV
    .assert (PC - SlotAddr) / 2 == REQ_CALL_SILENCE_AUDIO
.endproc


; ---------------------------------------------------------------------------
; handleAudio (M2RoS bank_004.asm:197)
; ---------------------------------------------------------------------------

.proc handleAudio
    mov A, V__audioPauseControl
    cmp A, #PAUSE__PAUSE
    bne NotPause
    jmp audioPause
NotPause:
    cmp A, #PAUSE__UNPAUSE
    bne NotUnpause
    jmp audioUnpause
NotUnpause:

    mov A, V__audioPauseSfxTimer
    cmp A, #0
    beq NotPaused
    jmp handleAudio_paused
NotPaused:

HandleSongInterruptionRequest:
    mov A, V__songInterruptionRequest
    cmp A, #0
    beq HandleSongInterruptionPlaying

    cmp A, #SONGINT__ITEM_GET
    bne NotItemGet
    jmp playSongInterruption_itemGet
NotItemGet:
    cmp A, #SONGINT__END_REQUEST
    bne NotEndRequest
    jmp startEndingSongInterruption
NotEndRequest:
    cmp A, #SONGINT__MISSILE_PICKUP
    bne NotMissilePickup
    jmp playSongInterruption_missilePickup
NotMissilePickup:
    cmp A, #SONGINT__FADE_OUT
    bne NotFadeOut
    jmp handleAudio_initiateFadingOutMusic
NotFadeOut:
    cmp A, #SONGINT__EARTHQUAKE
    bne NotEarthquake
    jmp playSongInterruption_earthquake
NotEarthquake:
    cmp A, #SONGINT__CLEAR
    bne NotClear
    call clearSongInterruption
NotClear:
    jmp handleSongAndSoundEffects

HandleSongInterruptionPlaying:
    mov A, V__songInterruptionPlaying
    cmp A, #0
    beq GoOn

    cmp A, #SONGINT__END_PLAYING
    bne NotEndPlaying
    jmp finishEndingSongInterruption
NotEndPlaying:
    cmp A, #SONGINT__FADE_OUT
    bne GoOn
    jmp handleAudio_handleFadingOutMusic
GoOn:
    jmp handleSongAndSoundEffects
.endproc


; The frame's work, and then every request byte cleared: the Game Boy engine
; consumes a request by acting on it and zeroing it, which is why a script
; repeats a request only when the game would.
.proc handleSongAndSoundEffects
    call handleSong
    call handleChannelSoundEffect_noise
    call handleChannelSoundEffect_square1
    call handleChannelSoundEffect_square2
    call handleChannelSoundEffect_wave
    mov A, #0
    mov V__songRequest, A
    mov V__sfxRequest_noise, A
    mov V__sfxRequest_square1, A
    mov V__sfxRequest_square2, A
    mov V__sfxRequest_fakeWave, A
    mov V__songInterruptionRequest, A
    mov V__sfxRequest_lowHealthBeep, A
    mov V__audioPauseControl, A
    ret
.endproc


.proc clearSongInterruption
    mov A, #0
    mov V__songInterruptionRequest, A
    mov V__songInterruptionPlaying, A
    ret
.endproc


; ---------------------------------------------------------------------------
; The song interruptions and the fade (M2RoS bank_004.asm:268-480)
; ---------------------------------------------------------------------------
;
; An interruption is a song that plays over another and gives it back: the
; item-get and missile-pickup jingles, and the earthquake. Starting one copies
; the whole song processing state aside, and ending one copies it back and
; replays the song's channel options into the registers. The request byte is
; in A on entry, as it is on the Game Boy, and three of these return without
; running `handleSongAndSoundEffects`: that tick plays nothing and clears no
; request, so the `songRequest` they set is picked up on the next tick, and the
; $FF stops `startEndingSongInterruption` sets survive `finishEnding...` too.

.proc playSongInterruption_itemGet
    mov V__songInterruptionPlaying, A
    mov A, #SONG__ITEM_GET
    mov V__songRequest, A
    jmp playSongInterruption
.endproc

.proc playSongInterruption_missilePickup
    mov V__songInterruptionPlaying, A
    mov A, #SONG__MISSILE_PICKUP
    mov V__songRequest, A
    jmp playSongInterruption
.endproc

; The earthquake's interruption id is its song id.
.proc playSongInterruption_earthquake
    mov V__songInterruptionPlaying, A
    mov V__songRequest, A
    ; falls through
.endproc

.proc playSongInterruption
    .assert PC == playSongInterruption_earthquake + 6
    mov A, V__songPlaying
    mov V__songPlayingBackup, A
    ; The earthquake leaves the low-health beep playing; the jingles save it
    ; and stop it.
    mov A, V__songInterruptionRequest
    cmp A, #SONGINT__EARTHQUAKE
    beq EndIf
    mov A, V__sfxPlaying_lowHealthBeep
    mov V__sfxPlayingBackup_lowHealthBeep, A
    mov A, #0
    mov V__sfxPlaying_lowHealthBeep, A
EndIf:
    mov A, V__stereoFlags
    mov V__stereoFlagsBackup, A
    mov A, V__songSweep_square1
    mov V__songSweepBackup_square1, A

    mov A, DATA__stateSizes + 2     ; songProcessingStateSize
    mov cnt, A
    mov Y, #0
Copy:
    mov A, V__songProcessingState+Y
    mov V__songProcessingStateBackup+Y, A
    inc Y
    dec cnt
    bne Copy

    call muteSoundChannels
    ; `muteSoundChannels` leaves A = 0 on the Game Boy, and these stores use it.
    mov A, #0
    mov V__songInterruptionRequest, A
    mov V__sfxRequest_square1, A
    mov V__sfxPlaying_square1, A
    mov V__sfxRequest_noise, A
    mov V__sfxPlaying_noise, A
    mov V__sfxActive_noise, A
    ret
.endproc

; A = $03, the end request; `songInterruptionPlaying` becomes $02, which the
; next tick's `finishEndingSongInterruption` is reached by.
.proc startEndingSongInterruption
    dec A
    mov V__songInterruptionPlaying, A

    mov A, DATA__stateSizes + 2     ; songProcessingStateSize
    mov cnt, A
    mov Y, #0
CopyState:
    mov A, V__songProcessingStateBackup+Y
    mov V__songProcessingState+Y, A
    inc Y
    dec cnt
    bne CopyState

    ; $CF10..$CF23 to $FF10..$FF23, all twenty, the two unused registers
    ; ($FF15, $FF1F) included: the Game Boy walks the range by address.
    mov cnt, #0
CopyOptions:
    mov Y, cnt
    mov A, V__songSweep_square1+Y
    mov X, cnt
    call SHIM_ENTRY__WRITE_REG
    inc cnt
    mov A, cnt
    cmp A, #REG__NR44 + 1
    bne CopyOptions

    mov A, #0
    mov V__songInterruptionRequest, A
    mov A, #$ff
    mov V__sfxRequest_square1, A
    mov V__sfxRequest_square2, A
    mov V__sfxRequest_noise, A
    ret
.endproc
.assert V__songSweep_square1 + REG__NR44 == V__songCounterControl_noise

.proc finishEndingSongInterruption
    mov A, V__songWavePatternDataPointer + 1
    mov de.h, A
    mov A, V__songWavePatternDataPointer + 0
    mov de.l, A
    ; No song has set a wave pattern: the Game Boy's own $0000, as in the
    ; wave channel's stop (`handleChannelSoundEffect_wave`).
    or A, de.h
    bne HavePattern
    mov de.l, #lobyte(DATA__rom0000)
    mov de.h, #hibyte(DATA__rom0000)
HavePattern:
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    call writeToWavePatternRam

    mov A, V__songPlaying
    cmp A, #SONG__EARTHQUAKE
    beq EndIf
    mov A, V__sfxPlayingBackup_lowHealthBeep
    mov V__sfxPlaying_lowHealthBeep, A
EndIf:
    mov A, V__stereoFlagsBackup
    mov V__stereoFlags, A
    mov ram_nr51, A
    mov X, #REG__NR51
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songSweepBackup_square1
    mov V__songSweep_square1, A
    mov A, #0
    mov V__songInterruptionPlaying, A
    mov V__ramCFEB, A
    mov A, V__songPlayingBackup
    mov V__songPlaying, A
    ret
.endproc

; A = $08. The note envelopes the fade is about to overwrite are copied to
; three bytes nothing reads, as on the Game Boy.
.proc handleAudio_initiateFadingOutMusic
    mov V__songInterruptionPlaying, A
    mov A, #$d0
    mov V__songFadeoutTimer, A
    mov A, V__state_square1 + STATE__noteEnvelope
    mov V__ramCF5D, A
    mov A, V__state_square2 + STATE__noteEnvelope
    mov V__ramCF5E, A
    mov A, V__state_wave + STATE__noteEnvelope
    mov V__ramCF5F, A
    jmp handleSongAndSoundEffects
.endproc

; $D0 ticks, quieter at $A0, $70, $30 and $10, and off at 0.
.proc handleAudio_handleFadingOutMusic
    mov A, V__songFadeoutTimer
    dec A
    mov V__songFadeoutTimer, A
    cmp A, #$a0
    beq TimerA0
    cmp A, #$70
    beq Timer70
    cmp A, #$30
    beq Timer30
    cmp A, #$10
    beq Timer10
    cmp A, #0
    beq Timer0
    jmp handleSongAndSoundEffects

TimerA0:
    mov A, #$65
    bra Merge
Timer70:
    mov A, #0
    mov V__songChannelEnable_noise, A
    mov A, #$60
    mov V__state_wave + STATE__noteEnvelope, A
    mov V__ramCF5F, A
    mov A, #$45
    bra Merge
Timer30:
    mov A, #$25
    bra Merge
Timer10:
    mov A, #$13
Merge:
    mov V__state_square1 + STATE__noteEnvelope, A
    mov V__state_square2 + STATE__noteEnvelope, A
    mov V__state_noise + STATE__noteEnvelope, A
    mov V__ramCF5D, A
    mov V__ramCF5E, A
    jmp handleSongAndSoundEffects

Timer0:
    mov A, #0
    mov V__songPlaying, A
    mov V__songInterruptionPlaying, A
    jmp disableSoundChannels
.endproc


; ---------------------------------------------------------------------------
; The pause (M2RoS bank_004.asm:1148-1289)
; ---------------------------------------------------------------------------
;
; Pausing mutes everything and plays a short sound of its own, eight option
; sets over $40 ticks alternating between the noise channel and square 1,
; while the song is held where it was: nothing runs `handleSong` until the
; unpause. The timer then stops at $10 and stays there until it is cleared.

; The eight sets inside `pausedOptionSets` (DATA__pausedOptionSets, 36 bytes
; from the Game Boy's $487C), by the timer value each is loaded at. The noise
; channel's are four bytes and square 1's five.
    PAUSED__frame40 = DATA__pausedOptionSets + $487C - $487C
    PAUSED__frame3D = DATA__pausedOptionSets + $4880 - $487C
    PAUSED__frame3F = DATA__pausedOptionSets + $4884 - $487C
    PAUSED__frame3A = DATA__pausedOptionSets + $4889 - $487C
    PAUSED__frame32 = DATA__pausedOptionSets + $488E - $487C
    PAUSED__frame2F = DATA__pausedOptionSets + $4892 - $487C
    PAUSED__frame27 = DATA__pausedOptionSets + $4897 - $487C
    PAUSED__frame24 = DATA__pausedOptionSets + $489B - $487C
    .assert PAUSED__frame24 + 5 == DATA__pausedOptionSets + $24

    SFX_SQ1__UNPAUSED = $1E

.proc audioPause
    call muteSoundChannels
    mov A, #0
    mov V__sfxPlaying_square1, A
    mov V__sfxPlaying_square2, A
    mov V__sfxPlaying_fakeWave, A
    mov V__sfxPlaying_noise, A
    mov A, #$40
    mov V__audioPauseSfxTimer, A
    mov de.l, #lobyte(PAUSED__frame40)
    mov de.h, #hibyte(PAUSED__frame40)
    jmp handleAudio_paused.NoiseSfx
.endproc

; The unpause sound is square 1's $1E, requested here and started by this
; same tick's `handleSongAndSoundEffects`.
.proc audioUnpause
    mov A, #0
    mov V__audioPauseSfxTimer, A
    mov A, #SFX_SQ1__UNPAUSED
    mov V__sfxRequest_square1, A
    jmp handleAudio.HandleSongInterruptionRequest
.endproc

.proc handleAudio_paused
    mov A, V__audioPauseSfxTimer
    dec A
    mov V__audioPauseSfxTimer, A
    cmp A, #$3f
    beq Frame3F
    cmp A, #$3d
    beq Frame3D
    cmp A, #$3a
    beq Frame3A
    cmp A, #$32
    beq Frame32
    cmp A, #$2f
    beq Frame2F
    cmp A, #$27
    beq Frame27
    cmp A, #$24
    beq Frame24
    cmp A, #$10
    bne Clear
    inc A
    mov V__audioPauseSfxTimer, A
Clear:
    jmp clearNonWaveSoundEffectRequests

Frame3D:
    mov de.l, #lobyte(PAUSED__frame3D)
    mov de.h, #hibyte(PAUSED__frame3D)
    bra NoiseSfx
Frame32:
    mov de.l, #lobyte(PAUSED__frame32)
    mov de.h, #hibyte(PAUSED__frame32)
    bra NoiseSfx
Frame27:
    mov de.l, #lobyte(PAUSED__frame27)
    mov de.h, #hibyte(PAUSED__frame27)
NoiseSfx:
    call setChannelOptionSet.Noise
    jmp clearNonWaveSoundEffectRequests

Frame3F:
    mov de.l, #lobyte(PAUSED__frame3F)
    mov de.h, #hibyte(PAUSED__frame3F)
    bra Square1Sfx
Frame3A:
    mov de.l, #lobyte(PAUSED__frame3A)
    mov de.h, #hibyte(PAUSED__frame3A)
    bra Square1Sfx
Frame2F:
    mov de.l, #lobyte(PAUSED__frame2F)
    mov de.h, #hibyte(PAUSED__frame2F)
    bra Square1Sfx
Frame24:
    mov de.l, #lobyte(PAUSED__frame24)
    mov de.h, #hibyte(PAUSED__frame24)
Square1Sfx:
    call setChannelOptionSet.Square1
    jmp clearNonWaveSoundEffectRequests
.endproc

; M2RoS bank_004.asm:1040. Every request but the wave channel's, so a beep
; requested while paused is still there at the unpause.
.proc clearNonWaveSoundEffectRequests
    mov A, #0
    mov V__sfxRequest_square1, A
    mov V__sfxRequest_square2, A
    mov V__sfxRequest_fakeWave, A
    mov V__sfxRequest_noise, A
    mov V__audioPauseControl, A
    ret
.endproc


; ---------------------------------------------------------------------------
; The square channels' sound effects (M2RoS bank_004.asm:482, :895, :2263-3710)
; ---------------------------------------------------------------------------
;
; Square 1 has thirty effects and square 2 seven, each an init routine that
; starts it and a playback routine that runs it one tick at a time, reached
; through a pair of pointer tables indexed by the id. Most playback routines
; are the same shape: count the timer down and, at particular values, load the
; next option set. They are transcribed one Game Boy routine to one procedure,
; in the Game Boy's order, so each reads beside the original.
;
; Four things about the shape that are easy to lose:
;
; - `decrementChannelSoundEffectTimer_*` returns the new timer in A, or clears
;   the effect when the timer was already 0 -- and then returns A = 0 from
;   `disableChannel_*`, which the caller goes on to compare. A playback routine
;   can therefore reach an option set on the tick its effect ended. That is the
;   Game Boy's behaviour and it is kept.
; - `setChannelOptionSet` is always reached by a jump, so its `ret` is the
;   handler's return.
; - `shim_write_reg` clobbers A where `ldh` does not, so a Game Boy store of A
;   after a register write is made before the write here.
; - The fake wave channel's request ($CECE) has no routines at all: bank 4 only
;   ever clears it, which `handleSongAndSoundEffects` does.

; handleChannelSoundEffect_square1 (M2RoS bank_004.asm:482)
;
; A request of $1F or more is not in the table and is ignored, which is what
; happens to the $2D the game writes at 02:$79A8. The missile-drop and
; health-change effects cannot be interrupted by another request, only stopped
; by $FF.
.proc handleChannelSoundEffect_square1
    mov A, V__sfxRequest_square1
    cmp A, #0
    beq Playing
    cmp A, #$ff
    bne NotStop
    jmp clearChannelSoundEffect_square1
NotStop:
    cmp A, #SFX_SQ1__END
    bcs Playing

    mov A, V__sfxPlaying_square1
    cmp A, #SFX_SQ1__PICKED_UP_MISSILE_DROP
    beq Playing
    cmp A, #SFX_SQ1__SAMUS_HEALTH_CHANGE
    beq Playing

    mov A, V__sfxRequest_square1
    dec A
    asl A
    mov X, A
    jmp [InitPointers+X]

Playing:
    mov A, V__sfxPlaying_square1
    cmp A, #0
    bne IsPlaying
    ret
IsPlaying:
    cmp A, #SFX_SQ1__END
    bcs NotInTable
    dec A
    asl A
    mov X, A
    jmp [PlaybackPointers+X]
NotInTable:
    mov A, #0
    mov V__sfxPlaying_square1, A
    ret

InitPointers:
    .dw square1Sfx_init_1               ; 1: jumping
    .dw square1Sfx_init_2               ; 2: hi-jumping
    .dw square1Sfx_init_3               ; 3: screw attacking
    .dw square1Sfx_init_4               ; 4: uncrouching / turning / landing / spike
    .dw square1Sfx_init_5               ; 5: crouching / unmorphing
    .dw square1Sfx_init_6               ; 6: morphing
    .dw square1Sfx_init_7               ; 7: shooting beam
    .dw square1Sfx_init_8               ; 8: shooting missile
    .dw square1Sfx_init_9               ; 9: shooting ice beam
    .dw square1Sfx_init_A               ; A: shooting plasma beam
    .dw square1Sfx_init_B               ; B: shooting spazer beam
    .dw square1Sfx_init_C               ; C: picked up missile drop
    .dw square1Sfx_init_D               ; D: spider ball
    .dw square1Sfx_init_E               ; E: picked up small energy drop
    .dw square1Sfx_init_F               ; F: beam hit a missile door
    .dw square1Sfx_init_10              ; 10: missile door exploding
    .dw sfxNothing                      ; 11: initializeAudio.ret
    .dw square1Sfx_init_12              ; 12: empty (duration 0)
    .dw square1Sfx_init_13              ; 13: bomb laid
    .dw square1Sfx_init_14              ; 14: pipe bug spawner stop
    .dw square1Sfx_init_15              ; 15: option / missile select
    .dw square1Sfx_init_16              ; 16: shooting wave beam
    .dw square1Sfx_init_17              ; 17: picked up large energy drop
    .dw square1Sfx_init_18              ; 18: Samus' health changed
    .dw square1Sfx_init_19              ; 19: no-missile dud shot
    .dw square1Sfx_init_1A              ; 1A: screw attacked / froze a Metroid
    .dw square1Sfx_init_1B              ; 1B: Metroid cry
    .dw square1Sfx_init_1C              ; 1C: saved
    .dw square1Sfx_init_1D              ; 1D: Varia suit transformation
    .dw square1Sfx_init_1E              ; 1E: unpaused

PlaybackPointers:
    .dw square1Sfx_playback_1
    .dw square1Sfx_playback_2
    .dw square1Sfx_playback_3
    .dw square1Sfx_playback_4
    .dw square1Sfx_playback_5
    .dw square1Sfx_playback_6
    .dw square1Sfx_playback_7
    .dw square1Sfx_playback_8
    .dw square1Sfx_playback_9
    .dw square1Sfx_playback_A
    .dw square1Sfx_playback_B
    .dw square1Sfx_playback_C
    .dw square1Sfx_playback_D
    .dw square1Sfx_playback_E
    .dw square1Sfx_playback_F
    .dw square1Sfx_playback_10
    .dw sfxNothing                      ; 11
    .dw decrementChannelSoundEffectTimer_square1 ; 12
    .dw decrementChannelSoundEffectTimer_square1 ; 13
    .dw square1Sfx_playback_14
    .dw square1Sfx_playback_15
    .dw square1Sfx_playback_16
    .dw square1Sfx_playback_17
    .dw decrementChannelSoundEffectTimer_square1 ; 18
    .dw square1Sfx_playback_19
    .dw square1Sfx_playback_1A
    .dw square1Sfx_playback_1B
    .dw square1Sfx_playback_1C
    .dw square1Sfx_playback_1D
    .dw square1Sfx_playback_1E
.endproc


; handleChannelSoundEffect_square2 (M2RoS bank_004.asm:524)
.proc handleChannelSoundEffect_square2
    mov A, V__sfxRequest_square2
    cmp A, #0
    beq Playing
    cmp A, #$ff
    bne NotStop
    jmp clearChannelSoundEffect_square2
NotStop:
    cmp A, #SFX_SQ2__END
    bcs Playing
    dec A
    asl A
    mov X, A
    jmp [InitPointers+X]

Playing:
    mov A, V__sfxPlaying_square2
    cmp A, #0
    bne IsPlaying
    ret
IsPlaying:
    cmp A, #SFX_SQ2__END
    bcs NotInTable
    dec A
    asl A
    mov X, A
    jmp [PlaybackPointers+X]
NotInTable:
    mov A, #0
    mov V__sfxPlaying_square2, A
    ret

InitPointers:
    .dw sfxNothing                      ; 1: initializeAudio.ret
    .dw sfxNothing                      ; 2: initializeAudio.ret
    .dw square2Sfx_init_3               ; 3: Metroid Queen cry
    .dw square2Sfx_init_4               ; 4: baby Metroid hatched / clearing blocks
    .dw square2Sfx_init_5               ; 5: baby Metroid cry
    .dw square2Sfx_init_6               ; 6: Metroid Queen hurt cry
    .dw square2Sfx_init_7               ; 7: Autom flamethrower

PlaybackPointers:
    .dw sfxNothing
    .dw sfxNothing
    .dw square2Sfx_playback_3
    .dw square2Sfx_playback_4
    .dw square2Sfx_playback_3           ; 5: the same routine as 3
    .dw square2Sfx_playback_3           ; 6: and again
    .dw decrementChannelSoundEffectTimer_square2 ; 7
.endproc


; `initializeAudio.ret`, which both tables point at for their empty ids.
.proc sfxNothing
    ret
.endproc


; M2RoS bank_004.asm:895 and :911
.proc decrementChannelSoundEffectTimer_square1
    mov A, V__sfxTimer_square1
    cmp A, #0
    bne Count
    jmp clearChannelSoundEffect_square1
Count:
    dec A
    mov V__sfxTimer_square1, A
    ret
.endproc

.proc decrementChannelSoundEffectTimer_square2
    mov A, V__sfxTimer_square2
    cmp A, #0
    bne Count
    jmp clearChannelSoundEffect_square2
Count:
    dec A
    mov V__sfxTimer_square2, A
    ret
.endproc


; de -> an option set, copied to the channel's registers in order (M2RoS
; bank_004.asm:1110). Square 1's is five bytes from NR10, square 2's four from
; NR21, the wave channel's five from NR30 and the noise channel's four from
; NR41. `de` is left past the set, as on the Game Boy.
.proc setChannelOptionSet
Square1:
    mov regidx, #REG__NR10
    mov cnt, #5
    bra Merge
Square2:
    mov regidx, #REG__NR21
    mov cnt, #4
    bra Merge
Wave:
    mov regidx, #REG__NR30
    mov cnt, #5
    bra Merge
Noise:
    mov regidx, #REG__NR41
    mov cnt, #4
Merge:
    mov Y, #0
    mov A, [de]+Y
    incw de
    mov X, regidx
    call SHIM_ENTRY__WRITE_REG
    inc regidx
    dbnz cnt, Merge
    ret
.endproc


; ---- Square 1 --------------------------------------------------------------

; M2RoS bank_004.asm:2331. Jumping in the Chozo ruins gets a short sound.
.proc playShortJumpSound
    mov A, #$0b
    mov de.l, #lobyte(OPT_SQ1__jumping_0)
    mov de.h, #hibyte(OPT_SQ1__jumping_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2338
.proc playingShortJumpSound
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$09
    bne Ret
    jmp square1Sfx_playback_1.Set1
Ret:
    ret
.endproc

; M2RoS bank_004.asm:2346. A jump does not cut off a beam shot, a missile or
; the wave beam; the spazer beam it does.
.proc square1Sfx_init_1
    mov A, V__sfxPlaying_square1
    cmp A, #SFX_SQ1__SHOOTING_WAVE_BEAM
    bne NotWaveBeam
    jmp handleChannelSoundEffect_square1.Playing
NotWaveBeam:
    cmp A, #SFX_SQ1__SHOOTING_BEAM
    bcc EndIf
    cmp A, #SFX_SQ1__SHOOTING_SPAZER_BEAM
    bcs EndIf
    jmp handleChannelSoundEffect_square1.Playing
EndIf:
    mov A, V__songPlaying
    cmp A, #SONG__CHOZO_RUINS
    bne Normal
    jmp playShortJumpSound
Normal:
    mov A, #$32
    mov de.l, #lobyte(OPT_SQ1__jumping_0)
    mov de.h, #hibyte(OPT_SQ1__jumping_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2367
.proc square1Sfx_playback_1
    mov A, V__songPlaying
    cmp A, #SONG__CHOZO_RUINS
    bne Normal
    jmp playingShortJumpSound
Normal:
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$2d
    beq Set1
    cmp A, #$1e
    beq Set2
    cmp A, #$18
    beq Set3
    cmp A, #$06
    beq Set4
    cmp A, #$01
    beq Set5
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__jumping_1)
    mov de.h, #hibyte(OPT_SQ1__jumping_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__jumping_2)
    mov de.h, #hibyte(OPT_SQ1__jumping_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__jumping_3)
    mov de.h, #hibyte(OPT_SQ1__jumping_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__jumping_4)
    mov de.h, #hibyte(OPT_SQ1__jumping_4)
    jmp setChannelOptionSet.Square1
Set5:
    mov de.l, #lobyte(OPT_SQ1__jumping_5)
    mov de.h, #hibyte(OPT_SQ1__jumping_5)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2407
.proc playShortHiJumpSound
    mov A, #$09
    mov de.l, #lobyte(OPT_SQ1__hijumping_0)
    mov de.h, #hibyte(OPT_SQ1__hijumping_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2414
.proc playingShortHiJumpSound
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$08
    bne Ret
    jmp square1Sfx_playback_2.Set1
Ret:
    ret
.endproc

; M2RoS bank_004.asm:2423
.proc square1Sfx_init_2
    mov A, V__sfxPlaying_square1
    cmp A, #SFX_SQ1__SHOOTING_WAVE_BEAM
    bne NotWaveBeam
    jmp handleChannelSoundEffect_square1.Playing
NotWaveBeam:
    cmp A, #SFX_SQ1__SHOOTING_BEAM
    bcc EndIf
    cmp A, #SFX_SQ1__SHOOTING_SPAZER_BEAM
    bcs EndIf
    jmp handleChannelSoundEffect_square1.Playing
EndIf:
    mov A, V__songPlaying
    cmp A, #SONG__CHOZO_RUINS
    bne Normal
    jmp playShortHiJumpSound
Normal:
    mov A, #$43
    mov de.l, #lobyte(OPT_SQ1__hijumping_0)
    mov de.h, #hibyte(OPT_SQ1__hijumping_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2444. (Its `.set0` is never branched to.)
.proc square1Sfx_playback_2
    mov A, V__songPlaying
    cmp A, #SONG__CHOZO_RUINS
    bne Normal
    jmp playingShortHiJumpSound
Normal:
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$41
    beq Set1
    cmp A, #$2d
    beq Set2
    cmp A, #$2b
    beq Set3
    cmp A, #$18
    beq Set4
    cmp A, #$15
    beq Set5
    cmp A, #$04
    beq Set6
    cmp A, #$01
    beq Set7
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__hijumping_1)
    mov de.h, #hibyte(OPT_SQ1__hijumping_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__hijumping_2)
    mov de.h, #hibyte(OPT_SQ1__hijumping_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__hijumping_3)
    mov de.h, #hibyte(OPT_SQ1__hijumping_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__hijumping_4)
    mov de.h, #hibyte(OPT_SQ1__hijumping_4)
    jmp setChannelOptionSet.Square1
Set5:
    mov de.l, #lobyte(OPT_SQ1__hijumping_5)
    mov de.h, #hibyte(OPT_SQ1__hijumping_5)
    jmp setChannelOptionSet.Square1
Set6:
    mov de.l, #lobyte(OPT_SQ1__hijumping_6)
    mov de.h, #hibyte(OPT_SQ1__hijumping_6)
    jmp setChannelOptionSet.Square1
Set7:
    mov de.l, #lobyte(OPT_SQ1__hijumping_7)
    mov de.h, #hibyte(OPT_SQ1__hijumping_7)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2500
.proc square1Sfx_init_3
    mov A, #$3f
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_0)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2507. The screw attack does not end: at 0 its timer goes
; back to $10 rather than clearing, and the last four sets repeat.
.proc square1Sfx_playback_3
    mov A, V__sfxTimer_square1
    cmp A, #0
    bne Count
    mov A, #$10                 ; .getTimerResetValue
Count:
    dec A
    mov V__sfxTimer_square1, A
    cmp A, #$3b
    beq Set1
    cmp A, #$37
    beq Set2
    cmp A, #$33
    beq Set3
    cmp A, #$2f
    beq Set4
    cmp A, #$2b
    beq Set5
    cmp A, #$27
    beq Set6
    cmp A, #$23
    beq Set7
    cmp A, #$1f
    beq Set8
    cmp A, #$1b
    beq Set9
    cmp A, #$17
    beq SetA
    cmp A, #$13
    beq SetB
    cmp A, #$0f
    beq SetA
    cmp A, #$0c
    beq SetB
    cmp A, #$09
    beq SetC
    cmp A, #$06
    beq SetD
    cmp A, #$03
    beq SetC
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_1)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_2)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_3)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_4)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_4)
    jmp setChannelOptionSet.Square1
Set5:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_5)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_5)
    jmp setChannelOptionSet.Square1
Set6:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_6)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_6)
    jmp setChannelOptionSet.Square1
Set7:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_7)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_7)
    jmp setChannelOptionSet.Square1
Set8:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_8)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_8)
    jmp setChannelOptionSet.Square1
Set9:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_9)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_9)
    jmp setChannelOptionSet.Square1
SetA:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_A)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_A)
    jmp setChannelOptionSet.Square1
SetB:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_B)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_B)
    jmp setChannelOptionSet.Square1
SetC:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_C)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_C)
    jmp setChannelOptionSet.Square1
SetD:
    mov de.l, #lobyte(OPT_SQ1__screwAttacking_D)
    mov de.h, #hibyte(OPT_SQ1__screwAttacking_D)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2606. Anything from the standing transition up keeps
; playing.
.proc square1Sfx_init_4
    mov A, V__sfxPlaying_square1
    cmp A, #SFX_SQ1__STANDING_TRANSITION
    bcc Start
    jmp handleChannelSoundEffect_square1.Playing
Start:
    mov A, #$0a
    mov de.l, #lobyte(OPT_SQ1__standingTransition_0)
    mov de.h, #hibyte(OPT_SQ1__standingTransition_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2617
.proc square1Sfx_playback_4
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$06
    beq Set1
    cmp A, #$02
    beq Set2
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__standingTransition_1)
    mov de.h, #hibyte(OPT_SQ1__standingTransition_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__standingTransition_2)
    mov de.h, #hibyte(OPT_SQ1__standingTransition_2)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2635
.proc square1Sfx_init_5
    mov A, #$0a
    mov de.l, #lobyte(OPT_SQ1__crouchingTransition_0)
    mov de.h, #hibyte(OPT_SQ1__crouchingTransition_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2642
.proc square1Sfx_playback_5
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$06
    beq Set1
    cmp A, #$02
    beq Set2
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__crouchingTransition_1)
    mov de.h, #hibyte(OPT_SQ1__crouchingTransition_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__crouchingTransition_2)
    mov de.h, #hibyte(OPT_SQ1__crouchingTransition_2)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2660
.proc square1Sfx_init_6
    mov A, #$0e
    mov de.l, #lobyte(OPT_SQ1__morphing_0)
    mov de.h, #hibyte(OPT_SQ1__morphing_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2667
.proc square1Sfx_playback_6
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$0b
    beq Set0
    cmp A, #$08
    beq Set1
    cmp A, #$03
    beq Set2
    ret
Set0:
    mov de.l, #lobyte(OPT_SQ1__morphing_0)
    mov de.h, #hibyte(OPT_SQ1__morphing_0)
    jmp setChannelOptionSet.Square1
Set1:
    mov de.l, #lobyte(OPT_SQ1__morphing_1)
    mov de.h, #hibyte(OPT_SQ1__morphing_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__morphing_2)
    mov de.h, #hibyte(OPT_SQ1__morphing_2)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2691
.proc square1Sfx_init_7
    mov A, #$0f
    mov de.l, #lobyte(OPT_SQ1__shootingBeam_0)
    mov de.h, #hibyte(OPT_SQ1__shootingBeam_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2698
.proc square1Sfx_playback_7
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$0d
    beq Set1
    cmp A, #$0b
    beq Set1
    cmp A, #$09
    beq Set2
    cmp A, #$07
    beq Set2
    cmp A, #$05
    beq Set3
    cmp A, #$03
    beq Set3
    cmp A, #$01
    beq Set4
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__shootingBeam_1)
    mov de.h, #hibyte(OPT_SQ1__shootingBeam_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__shootingBeam_2)
    mov de.h, #hibyte(OPT_SQ1__shootingBeam_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__shootingBeam_3)
    mov de.h, #hibyte(OPT_SQ1__shootingBeam_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__shootingBeam_4)
    mov de.h, #hibyte(OPT_SQ1__shootingBeam_4)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2734
.proc square1Sfx_init_8
    mov A, #$31
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_0)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2741
.proc square1Sfx_playback_8
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$2d
    beq Set1
    cmp A, #$25
    beq Set2
    cmp A, #$1a
    beq Set3
    cmp A, #$18
    beq Set4
    cmp A, #$15
    beq Set5
    cmp A, #$12
    beq Set6
    cmp A, #$0f
    beq Set7
    cmp A, #$0c
    beq Set8
    cmp A, #$09
    beq Set9
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_1)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_2)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_3)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_4)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_4)
    jmp setChannelOptionSet.Square1
Set5:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_5)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_5)
    jmp setChannelOptionSet.Square1
Set6:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_6)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_6)
    jmp setChannelOptionSet.Square1
Set7:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_7)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_7)
    jmp setChannelOptionSet.Square1
Set8:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_8)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_8)
    jmp setChannelOptionSet.Square1
Set9:
    mov de.l, #lobyte(OPT_SQ1__shootingMissile_9)
    mov de.h, #hibyte(OPT_SQ1__shootingMissile_9)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2801, :2819 and :2837: the ice, plasma and spazer shots
; differ only in their option set.
.proc square1Sfx_init_9
    mov A, #$d0
    mov V__sfxVariableFrequency_square1, A
    mov A, #$14
    mov de.l, #lobyte(OPT_SQ1__shootingIceBeam)
    mov de.h, #hibyte(OPT_SQ1__shootingIceBeam)
    jmp playSquare1Sfx
.endproc

.proc square1Sfx_init_A
    mov A, #$d0
    mov V__sfxVariableFrequency_square1, A
    mov A, #$14
    mov de.l, #lobyte(OPT_SQ1__shootingPlasmaBeam)
    mov de.h, #hibyte(OPT_SQ1__shootingPlasmaBeam)
    jmp playSquare1Sfx
.endproc

.proc square1Sfx_init_B
    mov A, #$d0
    mov V__sfxVariableFrequency_square1, A
    mov A, #$14
    mov de.l, #lobyte(OPT_SQ1__shootingSpazerBeam)
    mov de.h, #hibyte(OPT_SQ1__shootingSpazerBeam)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2810, :2828 and :2846 are three copies of this. Each
; stores the frequency back after writing it, unchanged, which is a no-op
; left out here.
.proc square1Sfx_playback_9
    call decrementChannelSoundEffectTimer_square1
    mov A, V__sfxVariableFrequency_square1
    mov X, #REG__NR13
    jmp SHIM_ENTRY__WRITE_REG
.endproc

    square1Sfx_playback_A = square1Sfx_playback_9
    square1Sfx_playback_B = square1Sfx_playback_9

; M2RoS bank_004.asm:2855
.proc square1Sfx_init_C
    mov A, #$14
    mov de.l, #lobyte(OPT_SQ1__pickingUpMissileDrop_0)
    mov de.h, #hibyte(OPT_SQ1__pickingUpMissileDrop_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2862
.proc square1Sfx_playback_C
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$0d
    beq Set1
    cmp A, #$0b
    beq Set2
    cmp A, #$08
    beq Set3
    cmp A, #$05
    beq Set4
    cmp A, #$03
    bne Ret
    jmp setPickedUpDropEndOptionSet
Ret:
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__pickingUpMissileDrop_1)
    mov de.h, #hibyte(OPT_SQ1__pickingUpMissileDrop_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__pickingUpMissileDrop_2)
    mov de.h, #hibyte(OPT_SQ1__pickingUpMissileDrop_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__pickingUpMissileDrop_3)
    mov de.h, #hibyte(OPT_SQ1__pickingUpMissileDrop_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__pickingUpMissileDrop_4)
    mov de.h, #hibyte(OPT_SQ1__pickingUpMissileDrop_4)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2894
.proc square1Sfx_init_D
    mov A, #$0d
    mov de.l, #lobyte(OPT_SQ1__spiderBall_0)
    mov de.h, #hibyte(OPT_SQ1__spiderBall_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2901
.proc square1Sfx_playback_D
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$03
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__spiderBall_1)
    mov de.h, #hibyte(OPT_SQ1__spiderBall_1)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2911
.proc square1Sfx_init_E
    call rememberIfScrewAttackingSfxIsPlaying
    mov A, #$0a
    mov de.l, #lobyte(OPT_SQ1__smallEnergyDrop_0)
    mov de.h, #hibyte(OPT_SQ1__smallEnergyDrop_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2919
.proc square1Sfx_playback_E
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$01
    bne NotLast
    jmp maybeResumeScrewAttackingSfx
NotLast:
    cmp A, #$08
    beq Set1
    cmp A, #$05
    beq Set2
    cmp A, #$03
    bne Ret
    jmp setPickedUpDropEndOptionSet
Ret:
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__smallEnergyDrop_1)
    mov de.h, #hibyte(OPT_SQ1__smallEnergyDrop_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__smallEnergyDrop_2)
    mov de.h, #hibyte(OPT_SQ1__smallEnergyDrop_2)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2941
.proc setPickedUpDropEndOptionSet
    mov de.l, #lobyte(OPT_SQ1__pickedUpDropEnd)
    mov de.h, #hibyte(OPT_SQ1__pickedUpDropEnd)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2947
.proc square1Sfx_init_F
    mov A, #$05
    mov de.l, #lobyte(OPT_SQ1__shotMissileDoorWithBeam_0)
    mov de.h, #hibyte(OPT_SQ1__shotMissileDoorWithBeam_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2954
.proc square1Sfx_playback_F
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$02
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__shotMissileDoorWithBeam_1)
    mov de.h, #hibyte(OPT_SQ1__shotMissileDoorWithBeam_1)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:2966
.proc square1Sfx_init_10
    mov A, #$16
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_0)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:2973
.proc square1Sfx_playback_10
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$14
    beq Set1
    cmp A, #$12
    beq Set2
    cmp A, #$10
    beq Set3
    cmp A, #$0e
    beq Set4
    cmp A, #$0c
    beq Set5
    cmp A, #$0a
    beq Set6
    cmp A, #$08
    beq Set7
    cmp A, #$06
    beq Set8
    cmp A, #$04
    beq Set9
    cmp A, #$02
    beq SetA
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_1)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_2)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_3)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_4)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_4)
    jmp setChannelOptionSet.Square1
Set5:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_5)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_5)
    jmp setChannelOptionSet.Square1
Set6:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_6)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_6)
    jmp setChannelOptionSet.Square1
Set7:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_7)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_7)
    jmp setChannelOptionSet.Square1
Set8:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_8)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_8)
    jmp setChannelOptionSet.Square1
Set9:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_9)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_9)
    jmp setChannelOptionSet.Square1
SetA:
    mov de.l, #lobyte(OPT_SQ1__missileDoorExploding_A)
    mov de.h, #hibyte(OPT_SQ1__missileDoorExploding_A)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3039. A timer of 0: the effect ends on its first playback
; tick, which is when `decrementChannelSoundEffectTimer` finds it at 0.
.proc square1Sfx_init_12
    mov A, #0
    mov de.l, #lobyte(OPT_SQ1__unused12)
    mov de.h, #hibyte(OPT_SQ1__unused12)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3046
.proc square1Sfx_init_13
    mov A, #$02
    mov de.l, #lobyte(OPT_SQ1__bombLaid)
    mov de.h, #hibyte(OPT_SQ1__bombLaid)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3053
.proc square1Sfx_init_14
    mov A, #$0e
    mov de.l, #lobyte(OPT_SQ1__pipeBugSpawnerStop_0)
    mov de.h, #hibyte(OPT_SQ1__pipeBugSpawnerStop_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3060
.proc square1Sfx_playback_14
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$06
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__pipeBugSpawnerStop_1)
    mov de.h, #hibyte(OPT_SQ1__pipeBugSpawnerStop_1)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3072
.proc square1Sfx_init_15
    mov A, #$04
    mov de.l, #lobyte(OPT_SQ1__optionMissileSelect_0)
    mov de.h, #hibyte(OPT_SQ1__optionMissileSelect_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3079
.proc square1Sfx_playback_15
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$02
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__optionMissileSelect_1)
    mov de.h, #hibyte(OPT_SQ1__optionMissileSelect_1)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3091
.proc square1Sfx_init_16
    mov A, #$1d
    mov de.l, #lobyte(OPT_SQ1__shootingWaveBeam_0)
    mov de.h, #hibyte(OPT_SQ1__shootingWaveBeam_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3098
.proc square1Sfx_playback_16
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$1a
    beq Set1
    cmp A, #$15
    beq Set1
    cmp A, #$11
    beq Set2
    cmp A, #$0d
    beq Set2
    cmp A, #$09
    beq Set3
    cmp A, #$05
    beq Set3
    cmp A, #$01
    beq Set4
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__shootingWaveBeam_1)
    mov de.h, #hibyte(OPT_SQ1__shootingWaveBeam_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__shootingWaveBeam_2)
    mov de.h, #hibyte(OPT_SQ1__shootingWaveBeam_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__shootingWaveBeam_3)
    mov de.h, #hibyte(OPT_SQ1__shootingWaveBeam_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__shootingWaveBeam_4)
    mov de.h, #hibyte(OPT_SQ1__shootingWaveBeam_4)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3134
.proc square1Sfx_init_17
    call rememberIfScrewAttackingSfxIsPlaying
    mov A, #$10
    mov de.l, #lobyte(OPT_SQ1__largeEnergyDrop_0)
    mov de.h, #hibyte(OPT_SQ1__largeEnergyDrop_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3142
.proc square1Sfx_playback_17
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$01
    bne NotLast
    jmp maybeResumeScrewAttackingSfx
NotLast:
    cmp A, #$0d
    beq Set1
    cmp A, #$0a
    beq Set2
    cmp A, #$08
    beq Set3
    cmp A, #$05
    beq Set4
    cmp A, #$02
    beq Set4
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__largeEnergyDrop_1)
    mov de.h, #hibyte(OPT_SQ1__largeEnergyDrop_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__largeEnergyDrop_2)
    mov de.h, #hibyte(OPT_SQ1__largeEnergyDrop_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__largeEnergyDrop_3)
    mov de.h, #hibyte(OPT_SQ1__largeEnergyDrop_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__largeEnergyDrop_4)
    mov de.h, #hibyte(OPT_SQ1__largeEnergyDrop_4)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3176
;
; The Game Boy's `call nz, .endIf` where it meant `jr`: with a nonzero index,
; the code from `EndIf` down runs once as a subroutine -- which can start the
; effect -- and then again from the top with the index forced to 2. M2RoS
; calls it a vanilla bug. It is kept, `call` for `call`, because it makes two
; rounds of register writes where the obvious reading makes one.
.proc square1Sfx_init_18
    mov A, V__samusHealthChangedOptionSetIndex
    cmp A, #0
    beq NoCall
    call EndIf
NoCall:
    mov A, #$02
    mov V__samusHealthChangedOptionSetIndex, A
EndIf:
    cmp A, #$01
    beq Set1
    cmp A, #$02
    beq Set0
    mov A, #$02
    mov V__samusHealthChangedOptionSetIndex, A
    ret
Set0:
    dec A
    mov V__samusHealthChangedOptionSetIndex, A
    mov A, #$02
    mov de.l, #lobyte(OPT_SQ1__samusHealthChanged_0)
    mov de.h, #hibyte(OPT_SQ1__samusHealthChanged_0)
    jmp playSquare1Sfx
Set1:
    dec A
    mov V__samusHealthChangedOptionSetIndex, A
    mov A, #$02
    mov de.l, #lobyte(OPT_SQ1__samusHealthChanged_1)
    mov de.h, #hibyte(OPT_SQ1__samusHealthChanged_1)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3209
.proc square1Sfx_init_19
    mov A, #$04
    mov de.l, #lobyte(OPT_SQ1__noMissileDudShot_0)
    mov de.h, #hibyte(OPT_SQ1__noMissileDudShot_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3216
.proc square1Sfx_playback_19
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$02
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__noMissileDudShot_1)
    mov de.h, #hibyte(OPT_SQ1__noMissileDudShot_1)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3228
.proc square1Sfx_init_1A
    mov A, #$16
    mov de.l, #lobyte(OPT_SQ1__metroidScrewAttacked_0)
    mov de.h, #hibyte(OPT_SQ1__metroidScrewAttacked_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3235
.proc square1Sfx_playback_1A
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$14
    beq Set1
    cmp A, #$12
    beq Set2
    cmp A, #$10
    beq Set1
    cmp A, #$0e
    beq Set3
    cmp A, #$0c
    beq Set1
    cmp A, #$0a
    beq Set4
    cmp A, #$08
    beq Set1
    cmp A, #$06
    beq Set5
    cmp A, #$04
    beq Set1
    cmp A, #$02
    beq Set6
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__metroidScrewAttacked_1)
    mov de.h, #hibyte(OPT_SQ1__metroidScrewAttacked_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__metroidScrewAttacked_2)
    mov de.h, #hibyte(OPT_SQ1__metroidScrewAttacked_2)
    jmp setChannelOptionSet.Square1
Set3:
    mov de.l, #lobyte(OPT_SQ1__metroidScrewAttacked_3)
    mov de.h, #hibyte(OPT_SQ1__metroidScrewAttacked_3)
    jmp setChannelOptionSet.Square1
Set4:
    mov de.l, #lobyte(OPT_SQ1__metroidScrewAttacked_4)
    mov de.h, #hibyte(OPT_SQ1__metroidScrewAttacked_4)
    jmp setChannelOptionSet.Square1
Set5:
    mov de.l, #lobyte(OPT_SQ1__metroidScrewAttacked_5)
    mov de.h, #hibyte(OPT_SQ1__metroidScrewAttacked_5)
    jmp setChannelOptionSet.Square1
Set6:
    mov de.l, #lobyte(OPT_SQ1__metroidScrewAttacked_6)
    mov de.h, #hibyte(OPT_SQ1__metroidScrewAttacked_6)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3285. The pitch is seeded from rDIV; see `ram_div`.
.proc square1Sfx_init_1B
    mov A, ram_div
    xcn A                       ; swap a
    or A, #%1110_0000           ; set 7, 6, 5
    and A, #%1111_1101          ; res 1
    mov V__sfxVariableFrequency_square1, A
    mov A, #$30
    mov de.l, #lobyte(OPT_SQ1__metroidCry)
    mov de.h, #hibyte(OPT_SQ1__metroidCry)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3299. Six `inc a` are an add of 6 to a byte.
.proc square1Sfx_playback_1B
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$20
    bcc Falling
    mov A, V__sfxVariableFrequency_square1
    clrc
    adc A, #6
    mov V__sfxVariableFrequency_square1, A
    mov X, #REG__NR13
    jmp SHIM_ENTRY__WRITE_REG
Falling:
    mov A, V__sfxVariableFrequency_square1
    dec A
    mov V__sfxVariableFrequency_square1, A
    mov X, #REG__NR13
    jmp SHIM_ENTRY__WRITE_REG
.endproc

; M2RoS bank_004.asm:3323
.proc square1Sfx_init_1C
    mov A, #$0f
    mov de.l, #lobyte(OPT_SQ1__saved0)
    mov de.h, #hibyte(OPT_SQ1__saved0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3330
.proc square1Sfx_playback_1C
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$0a
    beq Set1
    cmp A, #$03
    beq Set2
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__saved1)
    mov de.h, #hibyte(OPT_SQ1__saved1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__saved2)
    mov de.h, #hibyte(OPT_SQ1__saved2)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3348
.proc square1Sfx_init_1D
    mov A, #$90
    mov de.l, #lobyte(OPT_SQ1__variaSuitTransformation)
    mov de.h, #hibyte(OPT_SQ1__variaSuitTransformation)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3355
.proc square1Sfx_playback_1D
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$7e
    beq Set
    cmp A, #$6e
    beq Set
    cmp A, #$5e
    beq Set
    cmp A, #$4e
    beq Set
    cmp A, #$3e
    beq Set
    cmp A, #$2e
    beq Set
    cmp A, #$1e
    beq Set
    ret
Set:
    mov de.l, #lobyte(OPT_SQ1__variaSuitTransformation)
    mov de.h, #hibyte(OPT_SQ1__variaSuitTransformation)
    jmp setChannelOptionSet.Square1
.endproc

; M2RoS bank_004.asm:3379
.proc square1Sfx_init_1E
    mov A, #$0e
    mov de.l, #lobyte(OPT_SQ1__unpaused_0)
    mov de.h, #hibyte(OPT_SQ1__unpaused_0)
    jmp playSquare1Sfx
.endproc

; M2RoS bank_004.asm:3386
.proc square1Sfx_playback_1E
    call decrementChannelSoundEffectTimer_square1
    cmp A, #$0a
    beq Set1
    cmp A, #$03
    beq Set2
    ret
Set1:
    mov de.l, #lobyte(OPT_SQ1__unpaused_1)
    mov de.h, #hibyte(OPT_SQ1__unpaused_1)
    jmp setChannelOptionSet.Square1
Set2:
    mov de.l, #lobyte(OPT_SQ1__unpaused_2)
    mov de.h, #hibyte(OPT_SQ1__unpaused_2)
    jmp setChannelOptionSet.Square1
.endproc

; (M2RoS :3406-3517, the `example` routines, are in neither table and are not
; ported.)

; M2RoS bank_004.asm:3518. An energy drop picked up mid screw attack notes it,
; so that the screw attack's sound can come back when the drop's ends.
.proc rememberIfScrewAttackingSfxIsPlaying
    mov A, V__sfxPlaying_square1
    cmp A, #SFX_SQ1__SCREW_ATTACKING
    bne Ret
    mov V__resumeScrewAttackSoundEffectFlag, A
Ret:
    ret
.endproc

; M2RoS bank_004.asm:3528. The one place the engine reads game state: Samus
; still spin-jumping with the screw attack. See REQ_SAMUS_POSE.
.proc maybeResumeScrewAttackingSfx
    mov A, V__resumeScrewAttackSoundEffectFlag
    cmp A, #0
    beq Ret
    mov A, game_samusPose
    cmp A, #POSE__SPIN_JUMP
    bne Ret
    mov A, game_samusItems
    and A, #(1 << ITEM_BIT__SCREW)
    beq Ret
    mov A, #SFX_SQ1__SCREW_ATTACKING
    mov V__sfxPlaying_square1, A
    mov A, #0
    mov V__resumeScrewAttackSoundEffectFlag, A
Ret:
    ret
.endproc

; M2RoS bank_004.asm:3549. A = the timer, de -> the first option set.
.proc playSquare1Sfx
    mov V__sfxTimer_square1, A
    mov A, V__sfxRequest_square1
    mov V__sfxPlaying_square1, A
    mov V__sfxActive_square1, A
    jmp setChannelOptionSet.Square1
.endproc


; ---- Square 2 --------------------------------------------------------------
;
; The game requests $07 directly; $03-$06 seed their pitch from rDIV (see
; `ram_div`) and are requested by noise $09, $0A, $16 and $17.

; M2RoS bank_004.asm:3583
.proc square2Sfx_init_3
    mov A, ram_div
    xcn A                       ; swap a
    and A, #%0001_1111          ; res 7, 6, 5
    mov V__square2_variableFrequency, A
    mov A, #$30
    mov de.l, #lobyte(OPT_SQ2__metroidQueenCry)
    mov de.h, #hibyte(OPT_SQ2__metroidQueenCry)
    jmp playSquare2Sfx
.endproc

; M2RoS bank_004.asm:3596, shared by $03, $05 and $06.
.proc square2Sfx_playback_3
    call decrementChannelSoundEffectTimer_square2
    and A, #%0000_0001          ; bit 0, a
    beq Even
    mov A, V__square2_variableFrequency
    or A, #%0001_0000           ; set 4
    mov V__square2_variableFrequency, A
Merge:
    mov A, V__sfxTimer_square2
    cmp A, #$20
    bcc Part2
    mov A, V__square2_variableFrequency
    clrc
    adc A, #$03
    mov V__square2_variableFrequency, A
    mov X, #REG__NR23
    jmp SHIM_ENTRY__WRITE_REG
Even:
    mov A, V__square2_variableFrequency
    and A, #%1110_1111          ; res 4
    mov V__square2_variableFrequency, A
    bra Merge
Part2:
    mov A, V__square2_variableFrequency
    dec A
    mov V__square2_variableFrequency, A
    mov X, #REG__NR23
    jmp SHIM_ENTRY__WRITE_REG
.endproc

; M2RoS bank_004.asm:3633
.proc square2Sfx_init_4
    mov A, ram_div
    or A, #%1000_0000           ; set 7
    and A, #%1011_1111          ; res 6
    mov V__square2_variableFrequency, A
    mov A, #$1c
    mov de.l, #lobyte(OPT_SQ2__babyMetroidClearingBlock)
    mov de.h, #hibyte(OPT_SQ2__babyMetroidClearingBlock)
    jmp playSquare2Sfx
.endproc

; M2RoS bank_004.asm:3644
.proc square2Sfx_playback_4
    call decrementChannelSoundEffectTimer_square2
    cmp A, #$13
    beq Part2
    cmp A, #$0c
    beq Part3
    mov A, V__square2_variableFrequency
    inc A
    inc A
    mov V__square2_variableFrequency, A
    mov X, #REG__NR23
    jmp SHIM_ENTRY__WRITE_REG
Part2:
    mov A, #$a0
    mov V__square2_variableFrequency, A
    ret
Part3:
    mov A, #$90
    mov V__square2_variableFrequency, A
    ret
.endproc

; M2RoS bank_004.asm:3670
.proc square2Sfx_init_5
    mov A, ram_div
    xcn A                       ; swap a
    and A, #%0110_1011          ; res 7, 4, 2
    or A, #%0100_0000           ; set 6
    mov V__square2_variableFrequency, A
    mov A, #$30
    mov de.l, #lobyte(OPT_SQ2__babyMetroidCry)
    mov de.h, #hibyte(OPT_SQ2__babyMetroidCry)
    jmp playSquare2Sfx
.endproc

; M2RoS bank_004.asm:3684
.proc square2Sfx_init_6
    mov A, ram_div
    xcn A                       ; swap a
    and A, #%0111_1111          ; res 7
    or A, #%0100_0000           ; set 6
    mov V__square2_variableFrequency, A
    mov A, #$30
    mov de.l, #lobyte(OPT_SQ2__metroidQueenHurtCry)
    mov de.h, #hibyte(OPT_SQ2__metroidQueenHurtCry)
    jmp playSquare2Sfx
.endproc

; M2RoS bank_004.asm:3696
.proc square2Sfx_init_7
    mov A, #$01
    mov de.l, #lobyte(OPT_SQ2__automFlamethrower)
    mov de.h, #hibyte(OPT_SQ2__automFlamethrower)
    jmp playSquare2Sfx
.endproc

; M2RoS bank_004.asm:3703
.proc playSquare2Sfx
    mov V__sfxTimer_square2, A
    mov A, V__sfxRequest_square2
    mov V__sfxPlaying_square2, A
    mov V__sfxActive_square2, A
    jmp setChannelOptionSet.Square2
.endproc

; ---------------------------------------------------------------------------
; The noise and wave channels' sound effects (M2RoS bank_004.asm:557, :606,
; :3713-4357, :5409-5723)
; ---------------------------------------------------------------------------
;
; The noise channel has twenty-six effects, the same init-and-playback shape as
; the square channels'. Five of them also request a cry on a square channel,
; which that channel's handler starts later in the same tick, because
; `handleSongAndSoundEffects` runs the noise channel first; the cries seed
; their pitch from rDIV (REQ_DIV). The wave channel's five are the low-health
; beep, one per ten points of health below fifty, alternating two wave
; patterns.

; handleChannelSoundEffect_noise (M2RoS bank_004.asm:557)
;
; During the earthquake a noise request is dropped and nothing plays that tick.
; The Metroid-killed, Omega Metroid explosion and cleared-save effects cannot
; be cut off by another noise request, only stopped by $FF.
.proc handleChannelSoundEffect_noise
    mov A, V__sfxRequest_noise
    cmp A, #0
    beq Playing
    cmp A, #$ff
    bne NotStop
    jmp clearChannelSoundEffect_noise
NotStop:
    cmp A, #SFX_NOISE__END
    bcs Playing

    mov A, V__songPlaying
    cmp A, #SONG__EARTHQUAKE
    bne NotEarthquake
    ret
NotEarthquake:

    mov A, V__sfxPlaying_noise
    cmp A, #SFX_NOISE__METROID_KILLED
    beq Playing
    cmp A, #SFX_NOISE__OMEGA_METROID_EXPLOSION
    beq Playing
    cmp A, #SFX_NOISE__CLEARED_SAVE_FILE
    beq Playing

    mov A, V__sfxRequest_noise
    dec A
    asl A
    mov X, A
    jmp [InitPointers+X]

Playing:
    mov A, V__sfxPlaying_noise
    cmp A, #0
    bne IsPlaying
    ret
IsPlaying:
    ; An id past the table cannot be playing: only a request below $1B starts
    ; one. The Game Boy's branch for it writes to ROM (M2RoS notes the bug);
    ; there is nothing to port but the return.
    cmp A, #SFX_NOISE__END
    bcc InTable
    ret
InTable:
    dec A
    asl A
    mov X, A
    jmp [PlaybackPointers+X]

InitPointers:
    .dw noiseSfx_init_1                 ; 1: enemy shot
    .dw noiseSfx_init_2                 ; 2: enemy killed
    .dw noiseSfx_init_3                 ; 3: projectile explosion
    .dw noiseSfx_init_4                 ; 4: shot block destroyed
    .dw noiseSfx_init_5                 ; 5: Metroid hurt
    .dw noiseSfx_init_6                 ; 6: Samus hurt
    .dw noiseSfx_init_7                 ; 7: acid damage
    .dw noiseSfx_init_8                 ; 8: shot a missile block or door with a missile
    .dw noiseSfx_init_9                 ; 9: Metroid Queen cry
    .dw noiseSfx_init_A                 ; A: Metroid Queen hurt cry
    .dw noiseSfx_init_B                 ; B: Samus killed
    .dw noiseSfx_init_C                 ; C: bomb detonated
    .dw noiseSfx_init_D                 ; D: Metroid killed
    .dw noiseSfx_init_E                 ; E: Omega Metroid explosion
    .dw noiseSfx_init_F                 ; F: cleared save file
    .dw noiseSfx_init_10                ; 10: footsteps
    .dw noiseSfx_init_11                ; 11: rock icicle / drivel spit hit the ground
    .dw noiseSfx_init_12                ; 12: projectile fired
    .dw noiseSfx_init_13                ; 13: unused
    .dw noiseSfx_init_14                ; 14: Gamma Metroid lightning
    .dw noiseSfx_init_15                ; 15: Zeta / Omega Metroid fireball
    .dw noiseSfx_init_16                ; 16: baby Metroid hatched / clearing blocks
    .dw noiseSfx_init_17                ; 17: baby Metroid cry
    .dw noiseSfx_init_18                ; 18: Autrack rises
    .dw noiseSfx_init_19                ; 19: unused
    .dw noiseSfx_init_1A                ; 1A: Autoad jump

PlaybackPointers:
    .dw decrementChannelSoundEffectTimer_noise ; 1
    .dw noiseSfx_playback_2
    .dw decrementChannelSoundEffectTimer_noise ; 3
    .dw decrementChannelSoundEffectTimer_noise ; 4
    .dw noiseSfx_playback_5
    .dw noiseSfx_playback_6
    .dw noiseSfx_playback_7
    .dw noiseSfx_playback_8
    .dw noiseSfx_playback_9
    .dw noiseSfx_playback_A
    .dw noiseSfx_playback_B
    .dw noiseSfx_playback_C
    .dw noiseSfx_playback_D
    .dw noiseSfx_playback_E
    .dw noiseSfx_playback_F
    .dw noiseSfx_playback_10
    .dw noiseSfx_playback_11
    .dw noiseSfx_playback_11            ; 12: the same routine
    .dw noiseSfx_playback_11            ; 13: and again
    .dw noiseSfx_playback_14
    .dw noiseSfx_playback_15
    .dw decrementChannelSoundEffectTimer_noise ; 16
    .dw decrementChannelSoundEffectTimer_noise ; 17
    .dw noiseSfx_playback_18
    .dw decrementChannelSoundEffectTimer_noise ; 19
    .dw decrementChannelSoundEffectTimer_noise ; 1A
.endproc


; handleChannelSoundEffect_wave (M2RoS bank_004.asm:606)
;
; A request of $06 or more returns at once, and nothing plays that tick. $FF
; stops the beep and gives the channel back to the song: the song's wave
; pattern and its last options, unless the earthquake is playing.
.proc handleChannelSoundEffect_wave
    mov A, V__sfxRequest_wave
    cmp A, #0
    beq Playing
    cmp A, #$ff
    beq Stop
    cmp A, #SFX_WAVE__END
    bcc InTable
    ret
InTable:
    mov V__sfxActive_wave, A
    mov V__sfxPlaying_wave, A
    dec A
    asl A
    mov X, A
    jmp [InitPointers+X]

Playing:
    mov A, V__sfxPlaying_wave
    cmp A, #0
    bne IsPlaying
    ret
IsPlaying:
    cmp A, #SFX_WAVE__END
    bcs NotInTable
    dec A
    asl A
    mov X, A
    jmp [PlaybackPointers+X]
NotInTable:
    mov A, #0
    mov V__sfxPlaying_wave, A
    ret

Stop:
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songWavePatternDataPointer + 1
    mov de.h, A
    mov A, V__songWavePatternDataPointer + 0
    mov de.l, A
    ; No song has set a wave pattern, and the Game Boy copies its own address
    ; $0000 into wave RAM. Ours is the shim's direct page, so the ROM's bytes
    ; are placed in the data instead (`rom0000` in src/aram_layout.zig).
    or A, de.h
    bne HavePattern
    mov de.l, #lobyte(DATA__rom0000)
    mov de.h, #hibyte(DATA__rom0000)
HavePattern:
    call writeToWavePatternRam
    mov A, #0
    mov V__sfxActive_wave, A
    mov V__sfxRequest_wave, A
    mov V__sfxPlaying_wave, A
    mov A, V__songPlaying
    cmp A, #SONG__EARTHQUAKE
    bne Restore
    ret
Restore:
    mov A, V__songEnableOption_wave
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songSoundLength_wave
    mov X, #REG__NR31
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songVolume_wave
    mov X, #REG__NR32
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_wave + 0
    mov X, #REG__NR33
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_wave + 1
    mov X, #REG__NR34
    jmp SHIM_ENTRY__WRITE_REG

InitPointers:
    .dw waveSfx_init_1                  ; 1: health below 10
    .dw waveSfx_init_1                  ; 2: below 20, the same routine
    .dw waveSfx_init_3                  ; 3: below 30
    .dw waveSfx_init_4                  ; 4: below 40
    .dw waveSfx_init_5                  ; 5: below 50

PlaybackPointers:
    .dw waveSfx_playback_1
    .dw waveSfx_playback_1
    .dw waveSfx_playback_3
    .dw waveSfx_playback_4
    .dw waveSfx_playback_5
.endproc


; M2RoS bank_004.asm:927
.proc decrementChannelSoundEffectTimer_noise
    mov A, V__sfxTimer_noise
    cmp A, #0
    bne Count
    jmp clearChannelSoundEffect_noise
Count:
    dec A
    mov V__sfxTimer_noise, A
    ret
.endproc


; ---- Noise -----------------------------------------------------------------

; M2RoS bank_004.asm:3775
.proc noiseSfx_init_1
    mov A, #$0d
    mov de.l, #lobyte(OPT_NOISE__enemyShot)
    mov de.h, #hibyte(OPT_NOISE__enemyShot)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:3782
.proc noiseSfx_init_2
    mov A, #$19
    mov de.l, #lobyte(OPT_NOISE__enemyKilled_0)
    mov de.h, #hibyte(OPT_NOISE__enemyKilled_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_2
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$0d
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__enemyKilled_1)
    mov de.h, #hibyte(OPT_NOISE__enemyKilled_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:3801
.proc noiseSfx_init_3
    mov A, #$1d
    mov de.l, #lobyte(OPT_NOISE__enemyExplosion)
    mov de.h, #hibyte(OPT_NOISE__enemyExplosion)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:3808
.proc noiseSfx_init_4
    mov A, #$08
    mov de.l, #lobyte(OPT_NOISE__shotBlockDestroyed)
    mov de.h, #hibyte(OPT_NOISE__shotBlockDestroyed)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:3815. The Game Boy calls `playNoiseSweepSfx` here, where
; every other init jumps, and then runs on into the playback routine: the
; effect's first tick counts its timer down once, $40 to $3F, on the tick it
; starts.
.proc noiseSfx_init_5
    mov A, #SFX_SQ1__METROID_CRY
    mov V__sfxRequest_square1, A
    mov A, #$40
    mov de.l, #lobyte(OPT_NOISE__metroidHurt_0)
    mov de.h, #hibyte(OPT_NOISE__metroidHurt_0)
    call playNoiseSweepSfx
    jmp noiseSfx_playback_5
.endproc

.proc noiseSfx_playback_5
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$38
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__metroidHurt_1)
    mov de.h, #hibyte(OPT_NOISE__metroidHurt_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:3836
.proc noiseSfx_init_6
    mov A, #$14
    mov de.l, #lobyte(OPT_NOISE__SamusHurt_0)
    mov de.h, #hibyte(OPT_NOISE__SamusHurt_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_6
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$10
    beq Set1
    cmp A, #$0c
    beq Set0
    cmp A, #$08
    beq Set1
    ret
Set0:
    mov de.l, #lobyte(OPT_NOISE__SamusHurt_0)
    mov de.h, #hibyte(OPT_NOISE__SamusHurt_0)
    jmp setChannelOptionSet.Noise
Set1:
    mov de.l, #lobyte(OPT_NOISE__SamusHurt_1)
    mov de.h, #hibyte(OPT_NOISE__SamusHurt_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:3863
.proc noiseSfx_init_7
    mov A, #$08
    mov de.l, #lobyte(OPT_NOISE__acidDamage_0)
    mov de.h, #hibyte(OPT_NOISE__acidDamage_0)
    jmp playNoiseSweepSfx
.endproc

; Its second set is Samus hurt's, reached through that routine's label.
.proc noiseSfx_playback_7
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$05
    bne Ret
    jmp noiseSfx_playback_6.Set1
Ret:
    ret
.endproc

; M2RoS bank_004.asm:3878
.proc noiseSfx_init_8
    mov A, #$08
    mov de.l, #lobyte(OPT_NOISE__shotMissileDoor_0)
    mov de.h, #hibyte(OPT_NOISE__shotMissileDoor_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_8
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$05
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__shotMissileDoor_1)
    mov de.h, #hibyte(OPT_NOISE__shotMissileDoor_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:3897
.proc noiseSfx_init_9
    mov A, #SFX_SQ2__METROID_QUEEN_CRY
    mov V__sfxRequest_square2, A
    mov A, #$40
    mov de.l, #lobyte(OPT_NOISE__metroidQueenCry_0)
    mov de.h, #hibyte(OPT_NOISE__metroidQueenCry_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_9
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$38
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__metroidQueenCry_1)
    mov de.h, #hibyte(OPT_NOISE__metroidQueenCry_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:3918
.proc noiseSfx_init_A
    mov A, #SFX_SQ2__METROID_QUEEN_HURT_CRY
    mov V__sfxRequest_square2, A
    mov A, #$40
    mov de.l, #lobyte(OPT_NOISE__metroidQueenHurtCry_0)
    mov de.h, #hibyte(OPT_NOISE__metroidQueenHurtCry_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_A
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$38
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__metroidQueenHurtCry_1)
    mov de.h, #hibyte(OPT_NOISE__metroidQueenHurtCry_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:3939. Samus killed: three option sets, and between the
; second and the third the polynomial counter alone, stepped every four ticks.
.proc noiseSfx_init_B
    mov A, #$b0
    mov de.l, #lobyte(OPT_NOISE__samusKilled_0)
    mov de.h, #hibyte(OPT_NOISE__samusKilled_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_B
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$9f
    beq Set1
    cmp A, #$70
    beq Set2
    cmp A, #$6c
    beq P27
    cmp A, #$68
    beq P35
    cmp A, #$64
    beq P37
    cmp A, #$60
    beq P45
    cmp A, #$5c
    beq P47
    cmp A, #$58
    beq P55
    cmp A, #$54
    beq P57
    cmp A, #$50
    beq P65
    cmp A, #$4c
    beq P66
    cmp A, #$48
    beq P67
    cmp A, #$40
    beq Set3
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__samusKilled_1)
    mov de.h, #hibyte(OPT_NOISE__samusKilled_1)
    jmp setChannelOptionSet.Noise
Set2:
    mov de.l, #lobyte(OPT_NOISE__samusKilled_2)
    mov de.h, #hibyte(OPT_NOISE__samusKilled_2)
    jmp setChannelOptionSet.Noise
Set3:                                   ; setOptionSetSamusKilled_3
    mov de.l, #lobyte(OPT_NOISE__samusKilled_3)
    mov de.h, #hibyte(OPT_NOISE__samusKilled_3)
    jmp setChannelOptionSet.Noise
P27:
    mov A, #$27
    jmp setPolynomialCounter
P35:
    mov A, #$35
    jmp setPolynomialCounter
P37:
    mov A, #$37
    jmp setPolynomialCounter
P45:
    mov A, #$45
    jmp setPolynomialCounter
P47:
    mov A, #$47
    jmp setPolynomialCounter
P55:
    mov A, #$55
    jmp setPolynomialCounter
P57:
    mov A, #$57
    jmp setPolynomialCounter
P65:
    mov A, #$65
    jmp setPolynomialCounter
P66:
    mov A, #$66
    jmp setPolynomialCounter
P67:
    mov A, #$67
    jmp setPolynomialCounter
.endproc

; M2RoS bank_004.asm:3990-4058: ten routines, `setPolynomialCounter27` to
; `...67`, each one write of its own constant to NR43. Here the constant is
; loaded at each call site and the write is shared; the write is the same.
.proc setPolynomialCounter
    mov X, #REG__NR43
    jmp SHIM_ENTRY__WRITE_REG
.endproc

; M2RoS bank_004.asm:4062
.proc noiseSfx_init_C
    mov A, #$14
    mov de.l, #lobyte(OPT_NOISE__bombDetonated_0)
    mov de.h, #hibyte(OPT_NOISE__bombDetonated_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_C
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$0c
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__bombDetonated_1)
    mov de.h, #hibyte(OPT_NOISE__bombDetonated_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:4081
.proc noiseSfx_init_D
    mov A, #$35
    mov de.l, #lobyte(OPT_NOISE__metroidKilled_0)
    mov de.h, #hibyte(OPT_NOISE__metroidKilled_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_D
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$30
    beq P57
    cmp A, #$2c
    beq P35
    cmp A, #$27
    beq P37
    cmp A, #$23
    beq P55
    cmp A, #$20
    beq P47
    cmp A, #$1d
    beq P45
    cmp A, #$1a
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__metroidKilled_1)
    mov de.h, #hibyte(OPT_NOISE__metroidKilled_1)
    jmp setChannelOptionSet.Noise
P35:
    mov A, #$35
    jmp setPolynomialCounter
P37:
    mov A, #$37
    jmp setPolynomialCounter
P45:
    mov A, #$45
    jmp setPolynomialCounter
P47:
    mov A, #$47
    jmp setPolynomialCounter
P55:
    mov A, #$55
    jmp setPolynomialCounter
P57:
    mov A, #$57
    jmp setPolynomialCounter
.endproc

; M2RoS bank_004.asm:4112
.proc noiseSfx_init_E
    mov A, #$4f
    mov de.l, #lobyte(OPT_NOISE__omegaMetroidExplosion_0)
    mov de.h, #hibyte(OPT_NOISE__omegaMetroidExplosion_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_E
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$4d
    beq P65
    cmp A, #$4a
    beq P57
    cmp A, #$47
    beq P55
    cmp A, #$44
    beq P47
    cmp A, #$41
    beq P65
    cmp A, #$3e
    beq P57
    cmp A, #$3b
    beq P55
    cmp A, #$39
    beq P47
    cmp A, #$36
    beq P45
    cmp A, #$33
    beq P37
    cmp A, #$30
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__omegaMetroidExplosion_1)
    mov de.h, #hibyte(OPT_NOISE__omegaMetroidExplosion_1)
    jmp setChannelOptionSet.Noise
P37:
    mov A, #$37
    jmp setPolynomialCounter
P45:
    mov A, #$45
    jmp setPolynomialCounter
P47:
    mov A, #$47
    jmp setPolynomialCounter
P55:
    mov A, #$55
    jmp setPolynomialCounter
P57:
    mov A, #$57
    jmp setPolynomialCounter
P65:
    mov A, #$65
    jmp setPolynomialCounter
.endproc

; M2RoS bank_004.asm:4151
.proc noiseSfx_init_F
    mov A, #$70
    mov de.l, #lobyte(OPT_NOISE__clearedSaveFile_0)
    mov de.h, #hibyte(OPT_NOISE__clearedSaveFile_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_F
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$6d
    beq P67
    cmp A, #$6a
    beq P66
    cmp A, #$67
    beq P65
    cmp A, #$64
    beq P57
    cmp A, #$61
    beq P55
    cmp A, #$5e
    beq P47
    cmp A, #$5b
    beq P45
    cmp A, #$59
    beq P37
    cmp A, #$56
    beq P35
    cmp A, #$53
    beq P27
    cmp A, #$50
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__clearedSaveFile_1)
    mov de.h, #hibyte(OPT_NOISE__clearedSaveFile_1)
    jmp setChannelOptionSet.Noise
P27:
    mov A, #$27
    jmp setPolynomialCounter
P35:
    mov A, #$35
    jmp setPolynomialCounter
P37:
    mov A, #$37
    jmp setPolynomialCounter
P45:
    mov A, #$45
    jmp setPolynomialCounter
P47:
    mov A, #$47
    jmp setPolynomialCounter
P55:
    mov A, #$55
    jmp setPolynomialCounter
P57:
    mov A, #$57
    jmp setPolynomialCounter
P65:
    mov A, #$65
    jmp setPolynomialCounter
P66:
    mov A, #$66
    jmp setPolynomialCounter
P67:
    mov A, #$67
    jmp setPolynomialCounter
.endproc

; M2RoS bank_004.asm:4190. Footsteps give way to any noise effect already
; playing and to the song's own noise channel; then the request is treated as
; no request at all, and whatever is playing plays on.
.proc noiseSfx_init_10
    mov A, V__sfxPlaying_noise
    cmp A, #0
    beq NotPlaying
    jmp handleChannelSoundEffect_noise.Playing
NotPlaying:
    mov A, V__songChannelEnable_noise
    cmp A, #0
    beq Free
    jmp handleChannelSoundEffect_noise.Playing
Free:
    mov A, #$02
    mov de.l, #lobyte(OPT_NOISE__footsteps_0)
    mov de.h, #hibyte(OPT_NOISE__footsteps_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_10
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$01
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__footsteps_1)
    mov de.h, #hibyte(OPT_NOISE__footsteps_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:4217
.proc noiseSfx_init_11
    mov A, #$10
    mov de.l, #lobyte(OPT_NOISE__enemyHitGround_0)
    mov de.h, #hibyte(OPT_NOISE__enemyHitGround_0)
    jmp playNoiseSweepSfx
.endproc

; `noiseSfx_playback_11`, `_12` and `_13`: one routine, three labels.
.proc noiseSfx_playback_11
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$0c
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__misc_11_12_13_1)
    mov de.h, #hibyte(OPT_NOISE__misc_11_12_13_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:4238
.proc noiseSfx_init_12
    mov A, #$10
    mov de.l, #lobyte(OPT_NOISE__enemyProjectileFired_0)
    mov de.h, #hibyte(OPT_NOISE__enemyProjectileFired_0)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:4245
.proc noiseSfx_init_13
    mov A, #$10
    mov de.l, #lobyte(OPT_NOISE__autrackLaser_0)
    mov de.h, #hibyte(OPT_NOISE__autrackLaser_0)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:4252
.proc noiseSfx_init_14
    mov A, #$18
    mov de.l, #lobyte(OPT_NOISE__gammaMetroidLightning_0)
    mov de.h, #hibyte(OPT_NOISE__gammaMetroidLightning_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_14
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$10
    beq Set1
    cmp A, #$0c
    beq Set0
    cmp A, #$08
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__gammaMetroidLightning_1)
    mov de.h, #hibyte(OPT_NOISE__gammaMetroidLightning_1)
    jmp setChannelOptionSet.Noise
Set0:
    mov de.l, #lobyte(OPT_NOISE__gammaMetroidLightning_0)
    mov de.h, #hibyte(OPT_NOISE__gammaMetroidLightning_0)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:4279
.proc noiseSfx_init_15
    mov A, #$30
    mov de.l, #lobyte(OPT_NOISE__metroidFireball_0)
    mov de.h, #hibyte(OPT_NOISE__metroidFireball_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_15
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$20
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__metroidFireball_1)
    mov de.h, #hibyte(OPT_NOISE__metroidFireball_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:4298
.proc noiseSfx_init_16
    mov A, #SFX_SQ2__BABY_METROID_CLEARING_BLOCK
    mov V__sfxRequest_square2, A
    mov A, #$08
    mov de.l, #lobyte(OPT_NOISE__babyMetroidClearingBlock)
    mov de.h, #hibyte(OPT_NOISE__babyMetroidClearingBlock)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:4307
.proc noiseSfx_init_17
    mov A, #SFX_SQ2__BABY_METROID_CRY
    mov V__sfxRequest_square2, A
    mov A, #$40
    mov de.l, #lobyte(OPT_NOISE__babyMetroidCry)
    mov de.h, #hibyte(OPT_NOISE__babyMetroidCry)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:4316
.proc noiseSfx_init_18
    mov A, #$0f
    mov de.l, #lobyte(OPT_NOISE__autrackRises_0)
    mov de.h, #hibyte(OPT_NOISE__autrackRises_0)
    jmp playNoiseSweepSfx
.endproc

.proc noiseSfx_playback_18
    call decrementChannelSoundEffectTimer_noise
    cmp A, #$0c
    beq Set1
    ret
Set1:
    mov de.l, #lobyte(OPT_NOISE__autrackRises_1)
    mov de.h, #hibyte(OPT_NOISE__autrackRises_1)
    jmp setChannelOptionSet.Noise
.endproc

; M2RoS bank_004.asm:4335
.proc noiseSfx_init_19
    mov A, #$10
    mov de.l, #lobyte(OPT_NOISE__noMissileDudShot)
    mov de.h, #hibyte(OPT_NOISE__noMissileDudShot)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:4342
.proc noiseSfx_init_1A
    mov A, #$10
    mov de.l, #lobyte(OPT_NOISE__autoadJump)
    mov de.h, #hibyte(OPT_NOISE__autoadJump)
    jmp playNoiseSweepSfx
.endproc

; M2RoS bank_004.asm:4349. A = the timer, de -> the first option set.
.proc playNoiseSweepSfx
    mov V__sfxTimer_noise, A
    mov A, V__sfxRequest_noise
    mov V__sfxPlaying_noise, A
    mov V__sfxActive_noise, A
    jmp setChannelOptionSet.Noise
.endproc


; ---- Wave: the low-health beep ---------------------------------------------
;
; Each level is the same shape: start loud (wave pattern 4) for a few beeps,
; counted by `loudLowHealthBeepTimer`, then quiet (pattern 5). The playback
; routines set `sfxActive_wave` every tick, to one less than their own id --
; the Game Boy's values, kept as they are.

; M2RoS bank_004.asm:5430, `waveSfx_init_1` and `_2`. The Game Boy loads `de`
; twice here; once is the same.
.proc waveSfx_init_1
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov de.l, #lobyte(WAVE__wave4)
    mov de.h, #hibyte(WAVE__wave4)
    call writeToWavePatternRam
    mov A, #$0c
    mov V__loudLowHealthBeepTimer, A
    mov A, #$0e
    mov de.l, #lobyte(OPT_WAVE__healthUnder20_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder20_0)
    jmp playWaveSfx
.endproc

; M2RoS bank_004.asm:5444, `waveSfx_playback_1` and `_2`.
.proc waveSfx_playback_1
    mov A, #$01
    mov V__sfxActive_wave, A
    mov A, #$0a
    mov de.l, #lobyte(OPT_WAVE__healthUnder20_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder20_0)
    mov tmp.l, #lobyte(OPT_WAVE__healthUnder20_1)
    mov tmp.h, #hibyte(OPT_WAVE__healthUnder20_1)
    jmp lowHealthBeepPlayback
.endproc

; M2RoS bank_004.asm:5495
.proc waveSfx_init_3
    mov A, #$13
    mov de.l, #lobyte(OPT_WAVE__healthUnder30_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder30_0)
    jmp lowHealthBeepInit
.endproc

; M2RoS bank_004.asm:5508
.proc waveSfx_playback_3
    mov A, #$02
    mov V__sfxActive_wave, A
    mov A, #$09
    mov de.l, #lobyte(OPT_WAVE__healthUnder30_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder30_0)
    mov tmp.l, #lobyte(OPT_WAVE__healthUnder30_1)
    mov tmp.h, #hibyte(OPT_WAVE__healthUnder30_1)
    jmp lowHealthBeepPlayback
.endproc

; M2RoS bank_004.asm:5558
.proc waveSfx_init_4
    mov A, #$16
    mov de.l, #lobyte(OPT_WAVE__healthUnder40_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder40_0)
    jmp lowHealthBeepInit
.endproc

; M2RoS bank_004.asm:5571
.proc waveSfx_playback_4
    mov A, #$03
    mov V__sfxActive_wave, A
    mov A, #$09
    mov de.l, #lobyte(OPT_WAVE__healthUnder40_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder40_0)
    mov tmp.l, #lobyte(OPT_WAVE__healthUnder40_1)
    mov tmp.h, #hibyte(OPT_WAVE__healthUnder40_1)
    jmp lowHealthBeepPlayback
.endproc

; M2RoS bank_004.asm:5621
.proc waveSfx_init_5
    mov A, #$18
    mov de.l, #lobyte(OPT_WAVE__healthUnder50_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder50_0)
    jmp lowHealthBeepInit
.endproc

; M2RoS bank_004.asm:5634
.proc waveSfx_playback_5
    mov A, #$04
    mov V__sfxActive_wave, A
    mov A, #$0b
    mov de.l, #lobyte(OPT_WAVE__healthUnder50_0)
    mov de.h, #hibyte(OPT_WAVE__healthUnder50_0)
    mov tmp.l, #lobyte(OPT_WAVE__healthUnder50_1)
    mov tmp.h, #hibyte(OPT_WAVE__healthUnder50_1)
    jmp lowHealthBeepPlayback
.endproc

; The body of `waveSfx_init_3`, `_4` and `_5`, which differ only in the timer
; (A) and the first option set (de). The timer waits on the stack, because
; `writeToWavePatternRam` uses `asave`. The Game Boy has three copies; the
; writes are the same. Level 1-2's init differs (a longer loud run) and is
; written out above.
.proc lowHealthBeepInit
    push A
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    movw YA, de
    movw hlsave, YA
    mov de.l, #lobyte(WAVE__wave4)
    mov de.h, #hibyte(WAVE__wave4)
    call writeToWavePatternRam
    mov A, #$06
    mov V__loudLowHealthBeepTimer, A
    movw YA, hlsave
    movw de, YA
    pop A
    jmp playWaveSfx
.endproc

; The body of the five playback routines, which differ only in the tick the
; second set loads at (A), the first set (de) and the second (tmp). The Game
; Boy has four copies; the writes are the same.
;
; The timer counts down; at A the beep goes quiet (pattern 5 once the loud run
; is spent, with the channel off first) and the second set loads; at 0 the
; pattern is reloaded, the timer restarts from the effect's length and the
; first set loads again. The beep never ends by itself: only $FF stops it.
.proc lowHealthBeepPlayback
    mov asave, A
    mov A, V__sfxTimer_wave
    dec A
    mov V__sfxTimer_wave, A
    cmp A, asave
    beq Set1
    cmp A, #0
    beq Set0
    ret

Set1:
    mov A, V__loudLowHealthBeepTimer
    cmp A, #0
    beq Quiet1
    dec A
    mov V__loudLowHealthBeepTimer, A
    mov de.l, #lobyte(WAVE__wave4)
    mov de.h, #hibyte(WAVE__wave4)
    call writeToWavePatternRam
    bra EndIf1
Quiet1:
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov de.l, #lobyte(WAVE__wave5)
    mov de.h, #hibyte(WAVE__wave5)
    call writeToWavePatternRam
EndIf1:
    movw YA, tmp
    movw de, YA
    jmp setChannelOptionSet.Wave

Set0:
    movw YA, de
    movw hlsave, YA
    mov A, V__loudLowHealthBeepTimer
    cmp A, #0
    beq Quiet0
    mov de.l, #lobyte(WAVE__wave4)
    mov de.h, #hibyte(WAVE__wave4)
    call writeToWavePatternRam
    bra EndIf0
Quiet0:
    mov de.l, #lobyte(WAVE__wave5)
    mov de.h, #hibyte(WAVE__wave5)
    call writeToWavePatternRam
EndIf0:
    mov A, V__sfxLength_wave
    mov V__sfxTimer_wave, A
    movw YA, hlsave
    movw de, YA
    jmp setChannelOptionSet.Wave
.endproc

; M2RoS bank_004.asm:5719. A = the timer, and the length it restarts from.
.proc playWaveSfx
    mov V__sfxTimer_wave, A
    mov V__sfxLength_wave, A
    jmp setChannelOptionSet.Wave
.endproc


; ---------------------------------------------------------------------------
; handleSong (M2RoS bank_004.asm:670)
; ---------------------------------------------------------------------------

.proc handleSong
    mov A, V__songRequest
    cmp A, #0
    bne Requested
    jmp handleSongPlaying
Requested:

    cmp A, #$ff
    bne NotSilence
    jmp disableSoundChannels
NotSilence:

    cmp A, #SONG__KILLED_METROID
    bne NotKilledMetroid
    call clearChannelSoundEffect_square1
    call clearChannelSoundEffect_noise
    mov A, V__songRequest
NotKilledMetroid:

    cmp A, #$21
    bcc InRange
    jmp handleSongPlaying
InRange:

    mov V__songPlaying, A
    dec A
    ; songStereoFlags[songRequest - 1], to the shadow and to NR51.
    mov X, A
    mov A, DATA__songStereoFlags+X
    mov V__stereoFlags, A
    mov ram_nr51, A
    mov X, #REG__NR51
    call SHIM_ENTRY__WRITE_REG

    mov A, V__songRequest
    mov hl.l, #lobyte(DATA__songDataTable)
    mov hl.h, #hibyte(DATA__songDataTable)
    call loadPointerFromTable
    jmp loadSongHeader
.endproc


.proc disableSoundChannels
    mov A, #0
    mov V__songChannelEnable_square1, A
    mov V__songChannelEnable_square2, A
    mov V__songChannelEnable_wave, A
    mov V__songChannelEnable_noise, A
    call disableChannel_square1
    call disableChannel_square2
    call disableChannel_wave
    jmp disableChannel_noise
.endproc


.proc clearSongPlaying
    mov A, #0
    mov V__songPlaying, A
    ret
.endproc


; ---------------------------------------------------------------------------
; handleSongPlaying (M2RoS bank_004.asm:724)
; ---------------------------------------------------------------------------
;
; Four channels in order, one timer tick each. A channel whose timer reaches 1
; leaves here for its `loadNextChannelSound`, which reads the next instruction
; and comes back to this routine's own `endX` label -- so the four `endX`
; labels below are jump targets from four other procedures, and the chain
; through them is the Game Boy's control flow, not a convenience.
.proc handleSongPlaying
    mov A, V__songPlaying
    cmp A, #0
    bne Playing
    ret
Playing:

    cmp A, #$21
    bcc InRange
    jmp clearSongPlaying
InRange:

    mov A, #0
    mov V__songOptionsSetFlag_working, A
    mov A, V__songChannelEnable_square1
    cmp A, #0
    beq endSquare1

    mov A, #$01
    mov V__workingSoundChannel, A
    mov A, V__state_square1 + STATE__instructionTimer
    mov V__state_working + STATE__instructionTimer, A
    cmp A, #$01
    bne Square1Continues
    jmp handleSong_loadNextChannelSound_square1
Square1Continues:

    dec A
    mov V__state_square1 + STATE__instructionTimer, A
    mov A, V__sfxActive_square1
    cmp A, #0
    bne endSquare1

    mov A, V__state_square1 + STATE__effectIndex
    mov V__state_working + STATE__effectIndex, A
    cmp A, #0
    beq endSquare1

    mov A, V__songFrequency_square1
    mov bc.l, A
    mov A, V__songFrequency_square1 + 1
    mov bc.h, A
    call handleSongSoundChannelEffect
    mov A, V__songFrequency_working
    mov X, #REG__NR13
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_working + 1
    mov X, #REG__NR14
    call SHIM_ENTRY__WRITE_REG
endSquare1:

    mov A, #0
    mov V__songOptionsSetFlag_working, A
    mov A, V__songChannelEnable_square2
    cmp A, #0
    beq endSquare2

    mov A, #$02
    mov V__workingSoundChannel, A
    mov A, V__state_square2 + STATE__instructionTimer
    mov V__state_working + STATE__instructionTimer, A
    cmp A, #$01
    bne Square2Continues
    jmp handleSong_loadNextChannelSound_square2
Square2Continues:

    dec A
    mov V__state_square2 + STATE__instructionTimer, A
    mov A, V__sfxActive_square2
    cmp A, #0
    bne endSquare2

    mov A, V__state_square2 + STATE__effectIndex
    mov V__state_working + STATE__effectIndex, A
    cmp A, #0
    beq endSquare2

    mov A, V__songFrequency_square2
    mov bc.l, A
    mov A, V__songFrequency_square2 + 1
    mov bc.h, A
    call handleSongSoundChannelEffect
    mov A, V__songFrequency_working
    mov X, #REG__NR23
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_working + 1
    mov X, #REG__NR24
    call SHIM_ENTRY__WRITE_REG
endSquare2:

    mov A, #0
    mov V__songOptionsSetFlag_working, A
    mov A, V__songChannelEnable_wave
    cmp A, #0
    beq endWave

    mov A, #$03
    mov V__workingSoundChannel, A
    mov A, V__state_wave + STATE__instructionTimer
    mov V__state_working + STATE__instructionTimer, A
    cmp A, #$01
    bne WaveContinues
    jmp handleSong_loadNextChannelSound_wave
WaveContinues:

    dec A
    mov V__state_wave + STATE__instructionTimer, A
    mov A, V__sfxActive_wave
    cmp A, #0
    bne endWave

    mov A, V__state_wave + STATE__effectIndex
    mov V__state_working + STATE__effectIndex, A
    cmp A, #0
    beq endWave

    mov A, V__songFrequency_wave
    mov bc.l, A
    mov A, V__songFrequency_wave + 1
    mov bc.h, A
    call handleSongSoundChannelEffect
    mov A, V__songFrequency_working
    mov X, #REG__NR33
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_working + 1
    and A, #%0111_1111          ; res 7: the wave channel does not retrigger here
    mov X, #REG__NR34
    call SHIM_ENTRY__WRITE_REG
endWave:

    mov A, #0
    mov V__songOptionsSetFlag_working, A
    mov A, V__songChannelEnable_noise
    cmp A, #0
    beq endNoise

    mov A, #$04
    mov V__workingSoundChannel, A
    mov A, V__state_noise + STATE__instructionTimer
    mov V__state_working + STATE__instructionTimer, A
    cmp A, #$01
    bne NoiseContinues
    jmp handleSong_loadNextChannelSound_noise
NoiseContinues:

    dec A
    mov V__state_noise + STATE__instructionTimer, A
    ; The Game Boy returns here rather than falling through, so the song-ended
    ; check below is only ever reached with the noise channel disabled.
    ret
endNoise:

    ; A song ends when all four channels have run out of instructions.
    mov A, V__songChannelEnable_square1
    cmp A, #0
    bne Ret
    mov A, V__songChannelEnable_square2
    cmp A, #0
    bne Ret
    mov A, V__songChannelEnable_wave
    cmp A, #0
    bne Ret
    mov A, V__songChannelEnable_noise
    cmp A, #0
    bne Ret

    mov A, #0
    mov V__songPlaying, A
    mov V__songInterruptionPlaying, A
Ret:
    ret
.endproc


; hl = [[hl] + (a - 1) * 2]  (M2RoS bank_004.asm:879)
;
; The doubling is a byte's, and it wraps: an index of $80 or more folds back
; into the table's low half. That is the Game Boy's arithmetic, and the reason
; `asl` is right here where a 16-bit add would not be.
.proc loadPointerFromTable
    dec A
    asl A
    mov bc.l, A
    mov bc.h, #0
    movw YA, hl
    addw YA, bc
    movw hl, YA
    mov Y, #0
    mov A, [hl]+Y
    mov tmp.l, A
    inc Y
    mov A, [hl]+Y
    mov hl.h, A
    mov A, tmp.l
    mov hl.l, A
    ret
.endproc


; ---------------------------------------------------------------------------
; Clearing and disabling a channel (M2RoS bank_004.asm:952)
; ---------------------------------------------------------------------------

.proc clearChannelSoundEffect_square1
    mov A, #0
    mov V__sfxPlaying_square1, A
    mov V__sfxActive_square1, A
    jmp disableChannel_square1
.endproc

.proc disableChannel_square1
    mov A, #$08
    mov X, #REG__NR12
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR14
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    ret
.endproc

.proc clearChannelSoundEffect_square2
    mov A, #0
    mov V__sfxPlaying_square2, A
    mov V__sfxActive_square2, A
    jmp disableChannel_square2
.endproc

.proc disableChannel_square2
    mov A, #$08
    mov X, #REG__NR22
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR24
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    ret
.endproc

.proc clearChannelSoundEffect_wave
    mov A, #0
    mov V__sfxActive_wave, A
    jmp disableChannel_wave
.endproc

.proc disableChannel_wave
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    ret
.endproc

.proc clearChannelSoundEffect_noise
    mov A, #0
    mov V__sfxPlaying_noise, A
    mov V__sfxActive_noise, A
    jmp disableChannel_noise
.endproc

.proc disableChannel_noise
    mov A, #$08
    mov X, #REG__NR42
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR44
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    ret
.endproc


; Everything off, and every request and playing byte cleared (M2RoS :1049).
;
; Reached by a jump out of `loadNextSound` when a song's instruction stream
; holds $F6 or above, which is how a malformed stream stops the engine. The
; `ret` at the end of `muteSoundChannels` returns to whoever called
; `loadNextSound`, exactly as it does on the Game Boy.
.proc silenceAudio
    mov A, #$ff
    mov ram_nr51, A
    mov X, #REG__NR51
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    mov V__sfxRequest_square1, A
    mov V__sfxRequest_square2, A
    mov V__sfxRequest_fakeWave, A
    mov V__sfxRequest_noise, A
    mov V__sfxPlaying_square1, A
    mov V__sfxPlaying_square2, A
    mov V__sfxPlaying_fakeWave, A
    mov V__sfxPlaying_noise, A
    mov A, #$ff
    mov V__songRequest, A
    mov V__songPlaying, A
    mov A, #0
    mov V__songInterruptionRequest, A
    mov V__songInterruptionPlaying, A
    mov V__sfxRequest_wave, A
    mov V__sfxPlaying_wave, A
    mov V__audioPauseSfxTimer, A
    mov V__audioPauseControl, A
    jmp muteSoundChannels
.endproc


.proc muteSoundChannels
    mov A, #$08
    mov X, #REG__NR12
    call SHIM_ENTRY__WRITE_REG
    mov A, #$08
    mov X, #REG__NR22
    call SHIM_ENTRY__WRITE_REG
    mov A, #$08
    mov X, #REG__NR42
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR14
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR24
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR44
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    mov X, #REG__NR10
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    ret
.endproc


; de -> wave pattern RAM, sixteen bytes (M2RoS bank_004.asm:1090).
;
; The Game Boy walks the registers with `c`; here the index is on the direct
; page, because `shim_write_reg` clobbers X and Y and a register index cannot
; live in either across the call.
.proc writeToWavePatternRam
    mov cnt, #0
Loop:
    mov Y, cnt
    mov A, [de]+Y
    mov asave, A
    mov A, cnt
    clrc
    adc A, #REG__WAVE
    mov X, A
    mov A, asave
    call SHIM_ENTRY__WRITE_REG
    inc cnt
    mov A, cnt
    cmp A, #REG__WAVE_SIZE
    bne Loop
    ret
.endproc


; ---------------------------------------------------------------------------
; loadSongHeader (M2RoS bank_004.asm:1300)
; ---------------------------------------------------------------------------
;
; hl = the song's header. Eleven bytes: a transpose-and-tweak byte, the
; instruction timer array pointer, and one section pointer per channel. The
; pointers in RAM are big-endian -- high byte at +0 -- which is why each one is
; read low byte first and stored to +1.
;
; The header's own pointers were rewritten to ARAM addresses at build time
; (`src/audio_data.zig`'s relocation pass), so nothing here adds a bank offset.
.proc loadSongHeader
    call resetSongSoundChannelOptions

    mov Y, #0
    mov A, [hl]+Y
    inc Y
    mov asave, A
    and A, #%0000_0001
    beq NoFrequencyTweak
    mov A, #$01
    mov V__songFrequencyTweak_square2, A
NoFrequencyTweak:
    mov A, asave
    and A, #%1111_1110          ; res 0
    mov V__songTranspose, A

    mov A, [hl]+Y
    inc Y
    mov V__timerArrayPointer + 1, A
    mov A, [hl]+Y
    inc Y
    mov V__timerArrayPointer + 0, A

    mov A, [hl]+Y
    inc Y
    mov V__state_square1 + STATE__sectionPointer + 1, A
    mov A, [hl]+Y
    inc Y
    mov V__state_square1 + STATE__sectionPointer + 0, A
    mov A, [hl]+Y
    inc Y
    mov V__state_square2 + STATE__sectionPointer + 1, A
    mov A, [hl]+Y
    inc Y
    mov V__state_square2 + STATE__sectionPointer + 0, A
    mov A, [hl]+Y
    inc Y
    mov V__state_wave + STATE__sectionPointer + 1, A
    mov A, [hl]+Y
    inc Y
    mov V__state_wave + STATE__sectionPointer + 0, A
    mov A, [hl]+Y
    inc Y
    mov V__state_noise + STATE__sectionPointer + 1, A
    mov A, [hl]+Y
    mov V__state_noise + STATE__sectionPointer + 0, A

    ; Square 1. A section pointer of $0000 means the song does not use the
    ; channel, and the channel is silenced instead of started.
    mov A, V__state_square1 + STATE__sectionPointer + 0
    mov hl.h, A
    mov A, V__state_square1 + STATE__sectionPointer + 1
    mov hl.l, A
    or A, hl.h
    bne Square1Used
    mov A, #0
    mov V__songChannelEnable_square1, A
    mov A, #$08
    mov X, #REG__NR12
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR14
    call SHIM_ENTRY__WRITE_REG
    bra Square1Done
Square1Used:
    mov A, #$01
    mov V__songChannelEnable_square1, A
    mov Y, #0
    mov A, [hl]+Y
    mov V__insPtr_square1 + 1, A
    inc Y
    mov A, [hl]+Y
    mov V__insPtr_square1 + 0, A
Square1Done:

    mov A, V__state_square2 + STATE__sectionPointer + 0
    mov hl.h, A
    mov A, V__state_square2 + STATE__sectionPointer + 1
    mov hl.l, A
    or A, hl.h
    bne Square2Used
    mov A, #0
    mov V__songChannelEnable_square2, A
    mov A, #$08
    mov X, #REG__NR22
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR24
    call SHIM_ENTRY__WRITE_REG
    bra Square2Done
Square2Used:
    mov A, #$02
    mov V__songChannelEnable_square2, A
    mov Y, #0
    mov A, [hl]+Y
    mov V__insPtr_square2 + 1, A
    inc Y
    mov A, [hl]+Y
    mov V__insPtr_square2 + 0, A
Square2Done:

    mov A, V__state_wave + STATE__sectionPointer + 0
    mov hl.h, A
    mov A, V__state_wave + STATE__sectionPointer + 1
    mov hl.l, A
    or A, hl.h
    bne WaveUsed
    mov A, #0
    mov V__songChannelEnable_wave, A
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    bra WaveDone
WaveUsed:
    mov A, #$03
    mov V__songChannelEnable_wave, A
    mov Y, #0
    mov A, [hl]+Y
    mov V__insPtr_wave + 1, A
    inc Y
    mov A, [hl]+Y
    mov V__insPtr_wave + 0, A
WaveDone:

    mov A, V__state_noise + STATE__sectionPointer + 0
    mov hl.h, A
    mov A, V__state_noise + STATE__sectionPointer + 1
    mov hl.l, A
    or A, hl.h
    bne NoiseUsed
    mov A, #0
    mov V__songChannelEnable_noise, A
    bra NoiseDone
NoiseUsed:
    mov A, #$04
    mov V__songChannelEnable_noise, A
    mov Y, #0
    mov A, [hl]+Y
    mov V__insPtr_noise + 1, A
    inc Y
    mov A, [hl]+Y
    mov V__insPtr_noise + 0, A
NoiseDone:

    ; Every channel's first instruction is due on the next tick.
    mov A, #$01
    mov V__state_square1 + STATE__instructionTimer, A
    mov V__state_square2 + STATE__instructionTimer, A
    mov V__state_wave + STATE__instructionTimer, A
    mov V__state_noise + STATE__instructionTimer, A
    ret
.endproc


; The song processing states, cleared, and the channels muted (M2RoS :2226).
;
; The Game Boy saves and restores `hl` around the clear; this walks the block
; with Y instead and never touches it, which is the same thing said in fewer
; places -- `loadSongHeader` calls this with the header pointer live in `hl`.
.proc resetSongSoundChannelOptions
    mov A, DATA__stateSizes + 1     ; channelAllSongProcessingStateSizes
    mov cnt, A
    mov Y, #0
    mov A, #0
Loop:
    mov V__songProcessingStates+Y, A
    inc Y
    dec cnt
    bne Loop

    mov V__sfxActive_square1, A
    mov V__sfxActive_square2, A
    mov V__sfxActive_wave, A
    mov V__sfxActive_noise, A
    mov V__songFrequencyTweak_square2, A
    mov X, #REG__NR10
    call SHIM_ENTRY__WRITE_REG
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov A, #$08
    mov X, #REG__NR12
    call SHIM_ENTRY__WRITE_REG
    mov A, #$08
    mov X, #REG__NR22
    call SHIM_ENTRY__WRITE_REG
    mov A, #$08
    mov X, #REG__NR42
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR14
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR24
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov X, #REG__NR44
    call SHIM_ENTRY__WRITE_REG
    ret
.endproc


; The working state and a channel's, copied one way or the other (M2RoS :2025).
;
; de = source, hl = destination. The Game Boy leaves both advanced past the
; copy; every call site reloads them, so this walks with Y and leaves them be.
.proc copyChannelSongProcessingState
    mov A, DATA__stateSizes + 0     ; channelSongProcessingStateSize
    mov cnt, A
    mov Y, #0
Loop:
    mov A, [de]+Y
    mov [hl]+Y, A
    inc Y
    dec cnt
    bne Loop
    ret
.endproc


; ---------------------------------------------------------------------------
; The four channels' "load the next instruction" (M2RoS bank_004.asm:1428)
; ---------------------------------------------------------------------------

.proc handleSong_loadNextChannelSound_square1
    mov de.l, #lobyte(V__state_square1)
    mov de.h, #hibyte(V__state_square1)
    mov hl.l, #lobyte(V__state_working)
    mov hl.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__insPtr_square1 + 0
    mov hl.h, A
    mov A, V__insPtr_square1 + 1
    mov hl.l, A
    mov A, #$01
    call loadNextSound

    mov A, V__workingSoundChannel
    mov V__songChannelEnable_square1, A
    cmp A, #0
    bne StillPlaying
    jmp resetChannelOptions_square1
StillPlaying:

    mov A, hl.h
    mov V__insPtr_square1 + 0, A
    mov A, hl.l
    mov V__insPtr_square1 + 1, A
    mov hl.l, #lobyte(V__state_square1)
    mov hl.h, #hibyte(V__state_square1)
    mov de.l, #lobyte(V__state_working)
    mov de.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__songOptionsSetFlag_working
    cmp A, #$01
    bne NoOptions
    mov A, V__songSweep_working
    mov V__songSweep_square1, A
    mov A, V__songSoundLength_working
    mov V__songSoundLength_square1, A
NoOptions:

    mov A, V__songEnvelope_working
    mov V__songEnvelope_square1, A
    mov A, V__songFrequency_working
    mov V__songFrequency_square1, A
    mov A, V__songFrequency_working + 1
    mov V__songFrequency_square1 + 1, A

    mov A, V__sfxActive_square1
    cmp A, #0
    beq NoSfx
    jmp handleSongPlaying.endSquare1
NoSfx:

    mov A, V__songSweep_square1
    mov X, #REG__NR10
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songSoundLength_square1
    mov X, #REG__NR11
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songEnvelope_square1
    mov X, #REG__NR12
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_square1
    mov X, #REG__NR13
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_square1 + 1
    mov X, #REG__NR14
    call SHIM_ENTRY__WRITE_REG
    jmp handleSongPlaying.endSquare1
.endproc


.proc handleSong_loadNextChannelSound_square2
    mov de.l, #lobyte(V__state_square2)
    mov de.h, #hibyte(V__state_square2)
    mov hl.l, #lobyte(V__state_working)
    mov hl.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__insPtr_square2 + 0
    mov hl.h, A
    mov A, V__insPtr_square2 + 1
    mov hl.l, A
    mov A, #$02
    call loadNextSound

    mov A, V__workingSoundChannel
    mov V__songChannelEnable_square2, A
    cmp A, #0
    bne StillPlaying
    jmp resetChannelOptions_square2
StillPlaying:

    mov A, hl.h
    mov V__insPtr_square2 + 0, A
    mov A, hl.l
    mov V__insPtr_square2 + 1, A
    mov hl.l, #lobyte(V__state_square2)
    mov hl.h, #hibyte(V__state_square2)
    mov de.l, #lobyte(V__state_working)
    mov de.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__songOptionsSetFlag_working
    cmp A, #$02
    bne NoOptions
    mov A, V__songSoundLength_working
    mov V__songSoundLength_square2, A
NoOptions:

    mov A, V__songEnvelope_working
    mov V__songEnvelope_square2, A
    mov A, V__songFrequency_working
    mov V__songFrequency_square2, A
    mov A, V__songFrequency_working + 1
    mov V__songFrequency_square2 + 1, A

    mov A, V__sfxActive_square2
    cmp A, #0
    beq NoSfx
    jmp handleSongPlaying.endSquare2
NoSfx:

    mov A, V__songSoundLength_square2
    mov X, #REG__NR21
    call SHIM_ENTRY__WRITE_REG

    ; Some songs detune square 2 by a step or two, to beat against square 1.
    mov A, V__songFrequencyTweak_square2
    cmp A, #$01
    bne NoTweak
    mov A, V__songFrequency_square2
    mov hl.l, A
    mov A, V__songFrequency_square2 + 1
    mov hl.h, A
    cmp A, #$87
    bcs TweakOne
    incw hl
    incw hl
    bra TweakDone
TweakOne:
    incw hl
TweakDone:
    mov A, hl.l
    mov V__songFrequency_square2, A
    mov A, hl.h
    mov V__songFrequency_square2 + 1, A
NoTweak:

    mov A, V__songEnvelope_square2
    mov X, #REG__NR22
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_square2
    mov X, #REG__NR23
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_square2 + 1
    mov X, #REG__NR24
    call SHIM_ENTRY__WRITE_REG
    jmp handleSongPlaying.endSquare2
.endproc


.proc handleSong_loadNextChannelSound_wave
    mov de.l, #lobyte(V__state_wave)
    mov de.h, #hibyte(V__state_wave)
    mov hl.l, #lobyte(V__state_working)
    mov hl.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__insPtr_wave + 0
    mov hl.h, A
    mov A, V__insPtr_wave + 1
    mov hl.l, A
    mov A, #$03
    call loadNextSound

    mov A, V__workingSoundChannel
    mov V__songChannelEnable_wave, A
    cmp A, #0
    bne StillPlaying
    jmp resetChannelOptions_wave
StillPlaying:

    mov A, hl.h
    mov V__insPtr_wave + 0, A
    mov A, hl.l
    mov V__insPtr_wave + 1, A
    mov hl.l, #lobyte(V__state_wave)
    mov hl.h, #hibyte(V__state_wave)
    mov de.l, #lobyte(V__state_working)
    mov de.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__songEnable_working
    mov V__songEnableOption_wave, A
    mov A, V__songSoundLength_working
    mov V__songSoundLength_wave, A
    mov A, V__songVolume_working
    mov V__songVolume_wave, A
    mov A, V__songFrequency_working
    mov V__songFrequency_wave, A
    mov A, V__songFrequency_working + 1
    mov V__songFrequency_wave + 1, A

    mov A, V__sfxActive_wave
    cmp A, #0
    beq NoSfx
    jmp handleSongPlaying.endWave
NoSfx:

    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songEnableOption_wave
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songSoundLength_wave
    mov X, #REG__NR31
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songVolume_wave
    mov X, #REG__NR32
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_wave
    mov X, #REG__NR33
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songFrequency_wave + 1
    mov X, #REG__NR34
    call SHIM_ENTRY__WRITE_REG
    jmp handleSongPlaying.endWave
.endproc


.proc handleSong_loadNextChannelSound_noise
    mov de.l, #lobyte(V__state_noise)
    mov de.h, #hibyte(V__state_noise)
    mov hl.l, #lobyte(V__state_working)
    mov hl.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__insPtr_noise + 0
    mov hl.h, A
    mov A, V__insPtr_noise + 1
    mov hl.l, A
    mov A, #$04
    call loadNextSound

    mov A, V__workingSoundChannel
    mov V__songChannelEnable_noise, A
    cmp A, #0
    bne StillPlaying
    jmp resetChannelOptions_noise
StillPlaying:

    mov A, hl.h
    mov V__insPtr_noise + 0, A
    mov A, hl.l
    mov V__insPtr_noise + 1, A
    mov hl.l, #lobyte(V__state_noise)
    mov hl.h, #hibyte(V__state_noise)
    mov de.l, #lobyte(V__state_working)
    mov de.h, #hibyte(V__state_working)
    call copyChannelSongProcessingState

    mov A, V__sfxActive_noise
    cmp A, #0
    beq NoSfx
    ret
NoSfx:

    mov A, V__songSoundLength_working
    mov X, #REG__NR41
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songEnvelope_working
    mov X, #REG__NR42
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songPolyCounter_working
    mov V__songPolyCounter_noise, A
    mov X, #REG__NR43
    call SHIM_ENTRY__WRITE_REG
    mov A, V__songCounterControl_working
    mov V__songCounterControl_noise, A
    mov X, #REG__NR44
    call SHIM_ENTRY__WRITE_REG
    ret
.endproc


; A channel whose instructions have run out (M2RoS bank_004.asm:2177).
.proc resetChannelOptions_square1
    mov A, #0
    mov V__songChannelEnable_square1, A
    mov A, #$08
    mov V__songEnvelope_square1, A
    mov X, #REG__NR12
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov V__songFrequency_square1 + 1, A
    mov X, #REG__NR14
    call SHIM_ENTRY__WRITE_REG
    jmp handleSongPlaying.endSquare1
.endproc

.proc resetChannelOptions_square2
    mov A, #0
    mov V__songChannelEnable_square2, A
    mov A, #$08
    mov V__songEnvelope_square2, A
    mov X, #REG__NR22
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov V__songFrequency_square2 + 1, A
    mov X, #REG__NR24
    call SHIM_ENTRY__WRITE_REG
    jmp handleSongPlaying.endSquare2
.endproc

.proc resetChannelOptions_wave
    mov A, #0
    mov V__songChannelEnable_wave, A
    mov V__songEnableOption_wave, A
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    jmp handleSongPlaying.endWave
.endproc

.proc resetChannelOptions_noise
    mov A, #0
    mov V__songChannelEnable_noise, A
    mov A, #$08
    mov V__songEnvelope_noise, A
    mov X, #REG__NR42
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov V__songCounterControl_noise, A
    mov X, #REG__NR44
    call SHIM_ENTRY__WRITE_REG
    ret
.endproc


; ---------------------------------------------------------------------------
; loadNextSound (M2RoS bank_004.asm:1648)
; ---------------------------------------------------------------------------
;
; A = the working sound channel, hl = the channel's instruction pointer.
; Returns hl past the instruction it consumed and the working state filled in.
; A working sound channel of zero on return means the song's instruction lists
; ran out on this channel.
;
; Every pointer this walks was relocated to an ARAM address at build time, so
; the instruction stream, the section list, the tempo table and the wave
; patterns are all addressed directly.
.proc loadNextSound
    mov V__workingSoundChannel, A
    mov Y, #0
    mov A, [hl]+Y
    cmp A, #0
    bne Loop

NextInstructionList:
    ; The section list advances by one word. A word of $0000 ends the song on
    ; this channel; a word of $00F0 is a goto, and the word after it is where.
    mov A, V__state_working + STATE__sectionPointer + 0
    mov hl.h, A
    mov A, V__state_working + STATE__sectionPointer + 1
    mov hl.l, A
    incw hl
    incw hl
    mov A, hl.h
    mov V__state_working + STATE__sectionPointer + 0, A
    mov A, hl.l
    mov V__state_working + STATE__sectionPointer + 1, A

    mov Y, #0
    mov A, [hl]+Y
    cmp A, #0
    bne NotEndOfLists
    inc Y
    mov A, [hl]+Y
    cmp A, #0
    bne NotEndOfLists
    mov A, #0
    mov V__workingSoundChannel, A
    ret
NotEndOfLists:

    mov Y, #0
    mov A, [hl]+Y
    cmp A, #$f0
    bne NotGoto
    inc Y
    mov A, [hl]+Y
    cmp A, #0
    bne NotGoto
    call songInstruction_goto
NotGoto:

    ; The section's first word is the instruction list it names.
    mov Y, #0
    mov A, [hl]+Y
    mov tmp.l, A
    inc Y
    mov A, [hl]+Y
    mov hl.h, A
    mov A, tmp.l
    mov hl.l, A

Loop:
    mov Y, #0
    mov A, [hl]+Y
    cmp A, #$f1
    bne Not_f1
    call songInstruction_setWorkingSoundChannelOptions
Not_f1:
    cmp A, #$f2
    bne Not_f2
    call songInstruction_setInstructionTimerArrayPointer
Not_f2:
    cmp A, #$f3
    bne Not_f3
    call songInstruction_setMusicNoteOffset
Not_f3:
    cmp A, #$f4
    bne Not_f4
    call songInstruction_markRepeatPoint
Not_f4:
    cmp A, #$f5
    bne Not_f5
    call songInstruction_repeat
Not_f5:
    cmp A, #0
    bne NotEndOfList
    jmp NextInstructionList
NotEndOfList:

    cmp A, #$f6
    bcc NotSilence
    jmp silenceAudio
NotSilence:
    cmp A, #$f1
    bcc NotAnInstruction
    jmp Loop
NotAnInstruction:

    ; $9F and above is a note that carries its own length: the low bits index
    ; the song's tempo table, and the note itself is the byte after it.
    cmp A, #$9f
    bcc NoLength
    and A, #%0101_1111          ; res 7, res 5
    mov asave, A
    mov A, V__timerArrayPointer + 0
    mov bc.h, A
    mov A, V__timerArrayPointer + 1
    mov bc.l, A
    movw YA, hl
    movw hlsave, YA
    mov A, asave
    mov hl.l, A
    mov hl.h, #0
    movw YA, hl
    addw YA, bc
    movw hl, YA
    mov Y, #0
    mov A, [hl]+Y
    mov tmp.l, A
    movw YA, hlsave
    movw hl, YA
    mov A, tmp.l
    mov V__state_working + STATE__instructionTimer, A
    mov V__state_working + STATE__instructionLength, A
    incw hl
NoLength:

    mov A, V__state_working + STATE__instructionLength
    mov V__state_working + STATE__instructionTimer, A
    mov A, V__workingSoundChannel
    cmp A, #$04
    bne NotNoise
    jmp Noise
NotNoise:

    mov Y, #0
    mov A, [hl]+Y
    incw hl
    cmp A, #$01
    bne NotRest
    jmp SongRest
NotRest:
    cmp A, #$03
    bne NotEcho1
    jmp Echo1
NotEcho1:
    cmp A, #$05
    bne NotEcho2
    jmp Echo2
NotEcho2:

    mov asave, A
    movw YA, hl
    movw hlsave, YA

    ; A note on the wave channel routes itself to both speakers and re-enables
    ; the channel, unless a sound effect has the channel.
    mov A, V__workingSoundChannel
    cmp A, #$03
    bne NotWave
    mov A, V__sfxActive_wave
    cmp A, #0
    bne NotWave
    ; Two writes, not one: the Game Boy sets the two bits with two `set b,[hl]`
    ; instructions on the register itself, and each of those is a write the APU
    ; sees. Folding them into one `or` would play the same note and grade as a
    ; missing write.
    mov A, ram_nr51
    or A, #%0100_0000           ; set 6
    mov ram_nr51, A
    mov X, #REG__NR51
    call SHIM_ENTRY__WRITE_REG
    mov A, ram_nr51
    or A, #%0000_0100           ; set 2
    mov ram_nr51, A
    mov X, #REG__NR51
    call SHIM_ENTRY__WRITE_REG
    mov A, #$80
    mov V__songEnable_working, A
NotWave:

    ; The note, transposed, indexes `musicNotes`; the entry is an NR13/NR14
    ; pair, so the trigger bit rides along with the period.
    mov A, asave
    mov bc.l, A
    mov A, V__workingSoundChannel
    cmp A, #$04
    beq NoTranspose
    mov A, V__songTranspose
    clrc
    adc A, bc.l
NoTranspose:
    mov bc.l, A
    mov bc.h, #0
    mov hl.l, #lobyte(DATA__musicNotes)
    mov hl.h, #hibyte(DATA__musicNotes)
    movw YA, hl
    addw YA, bc
    movw hl, YA

    mov A, V__state_working + STATE__noteEnvelope
    mov V__songEnvelope_working, A
    mov Y, #0
    mov A, [hl]+Y
    mov V__songFrequency_working, A
    inc Y
    mov A, [hl]+Y
    mov V__songFrequency_working + 1, A
    movw YA, hlsave
    movw hl, YA
    ret

SongRest:
    mov A, V__workingSoundChannel
    cmp A, #$03
    beq RestartChannel
    mov A, #$08
    mov V__songEnvelope_working, A
    mov A, #$80
    mov V__songCounterControl_working, A
    ret
RestartChannel:
    mov A, #0
    mov V__songEnable_working, A
    mov V__songVolume_working, A
    ret

Noise:
    mov Y, #0
    mov A, [hl]+Y
    incw hl
    cmp A, #$01
    beq SongRest

    mov bc.l, A
    mov bc.h, #0
    movw YA, hl
    movw hlsave, YA
    mov hl.l, #lobyte(DATA__songNoiseOptionSets)
    mov hl.h, #hibyte(DATA__songNoiseOptionSets)
    movw YA, hl
    addw YA, bc
    movw hl, YA
    mov Y, #0
    mov A, [hl]+Y
    mov V__songSoundLength_working, A
    inc Y
    mov A, [hl]+Y
    mov V__songEnvelope_working, A
    inc Y
    mov A, [hl]+Y
    mov V__songPolyCounter_working, A
    inc Y
    mov A, [hl]+Y
    mov V__songCounterControl_working, A
    movw YA, hlsave
    movw hl, YA
    ret

Echo1:
    mov A, #$66
    mov V__songEnvelope_working, A
    bra Merge
Echo2:
    mov A, #$46
    mov V__songEnvelope_working, A
Merge:
    mov A, V__songInterruptionPlaying
    cmp A, #SONGINT__FADE_OUT
    bne NotFadingOut
    mov A, #SONGINT__FADE_OUT
    mov V__songEnvelope_working, A
NotFadingOut:

    ; An echo repeats the channel's current note rather than naming one.
    mov A, V__workingSoundChannel
    cmp A, #$01
    beq EchoSquare1
    cmp A, #$02
    beq EchoSquare2
    cmp A, #$03
    beq EchoWave
    ret

EchoSquare1:
    mov A, V__songFrequency_square1
    mov V__songFrequency_working, A
    mov A, V__songFrequency_square1 + 1
    mov V__songFrequency_working + 1, A
    ret

EchoSquare2:
    mov A, V__songFrequency_square2
    mov V__songFrequency_working, A
    mov A, V__songFrequency_square2 + 1
    mov V__songFrequency_working + 1, A
    ret

EchoWave:
    mov A, V__sfxActive_wave
    cmp A, #0
    bne EchoWaveDone
    mov A, #$80
    mov V__songEnable_working, A
    mov A, V__songFrequency_wave
    mov V__songFrequency_working, A
    mov A, V__songFrequency_wave + 1
    mov V__songFrequency_working + 1, A
EchoWaveDone:
    ret
.endproc


; ---------------------------------------------------------------------------
; The five song instructions (M2RoS bank_004.asm:1883)
; ---------------------------------------------------------------------------
;
; Each is entered with hl on its opcode and returns with A = the byte hl then
; points at, so `loadNextSound`'s dispatch chain carries straight on with it.

; $F1: set the working channel's options.
.proc songInstruction_setWorkingSoundChannelOptions
    incw hl
    mov A, V__workingSoundChannel
    mov V__songOptionsSetFlag_working, A
    cmp A, #$03
    bne NotWave
    jmp songInstruction_setWorkingSoundChannelOptions_wave
NotWave:

    mov Y, #0
    mov A, [hl]+Y
    incw hl
    mov V__songEnvelope_working, A
    mov asave, A
    mov A, V__songInterruptionPlaying
    cmp A, #SONGINT__FADE_OUT
    beq FadingOut
    ; Not fading: the envelope is the note's too, so a later echo repeats it.
    mov A, asave
    mov V__state_working + STATE__noteEnvelope, A
FadingOut:

    mov Y, #0
    mov A, [hl]+Y
    incw hl
    mov V__songSweep_working, A
    mov A, [hl]+Y
    mov V__songSoundLength_working, A
    and A, #%0011_1111          ; res 6, res 7
    jmp endSongInstruction.effectIndex
.endproc


; $F1 on the wave channel: a wave pattern and a volume instead.
.proc songInstruction_setWorkingSoundChannelOptions_wave
    mov Y, #0
    mov A, [hl]+Y
    incw hl
    mov V__songWavePatternDataPointer + 0, A
    mov V__ramCFE3 + 0, A
    mov de.l, A
    mov A, [hl]+Y
    incw hl
    mov V__songWavePatternDataPointer + 1, A
    mov V__ramCFE3 + 1, A
    mov de.h, A

    mov A, [hl]+Y
    mov V__songVolume_working, A
    mov asave, A
    mov A, V__songInterruptionPlaying
    cmp A, #SONGINT__FADE_OUT
    beq FadingOut
    mov A, asave
    mov V__state_working + STATE__noteEnvelope, A
FadingOut:

    mov A, V__sfxActive_wave
    cmp A, #0
    bne SfxHasTheChannel
    mov A, #0
    mov X, #REG__NR30
    call SHIM_ENTRY__WRITE_REG
    call writeToWavePatternRam
SfxHasTheChannel:

    mov A, V__songVolume_working
    and A, #%1001_1111          ; res 5, res 6
    jmp endSongInstruction.effectIndex
.endproc


; $F2: the song's tempo, as a pointer to one of the instruction timer arrays.
.proc songInstruction_setInstructionTimerArrayPointer
    incw hl
    mov Y, #0
    mov A, [hl]+Y
    incw hl
    mov V__timerArrayPointer + 1, A
    mov A, [hl]+Y
    incw hl
    mov V__timerArrayPointer + 0, A
    jmp endSongInstruction
.endproc


; $F3: transpose every note from here on.
.proc songInstruction_setMusicNoteOffset
    incw hl
    mov Y, #0
    mov A, [hl]+Y
    incw hl
    mov V__songTranspose, A
    jmp endSongInstruction
.endproc


; $00F0 in a section list: the list continues at the word after it.
.proc songInstruction_goto
    incw hl
    incw hl
    mov Y, #0
    mov A, [hl]+Y
    incw hl
    mov V__state_working + STATE__sectionPointer + 1, A
    mov bc.l, A
    mov A, [hl]+Y
    mov V__state_working + STATE__sectionPointer + 0, A
    mov hl.h, A
    mov A, bc.l
    mov hl.l, A
    ret
.endproc


; $F4: this is where $F5 comes back to, this many times.
.proc songInstruction_markRepeatPoint
    incw hl
    mov Y, #0
    mov A, [hl]+Y
    incw hl
    mov V__state_working + STATE__repeatPoint, A
    mov A, hl.h
    mov V__state_working + STATE__repeatCount + 0, A
    mov A, hl.l
    mov V__state_working + STATE__repeatCount + 1, A
    jmp endSongInstruction
.endproc


; $F5: go back to the $F4, unless the count has run out.
.proc songInstruction_repeat
    mov A, V__state_working + STATE__repeatPoint
    dec A
    mov V__state_working + STATE__repeatPoint, A
    cmp A, #0
    beq Done
    mov A, V__state_working + STATE__repeatCount + 0
    mov hl.h, A
    mov A, V__state_working + STATE__repeatCount + 1
    mov hl.l, A
    ; A repeat point no $F4 set is still $0000, and the Game Boy reads its own
    ; address $0000 as song data. Ours is the shim's direct page, so the ROM's
    ; bytes are placed in the data instead (`rom0000` in src/aram_layout.zig).
    or A, hl.h
    bne Repeat
    mov hl.l, #lobyte(DATA__rom0000)
    mov hl.h, #hibyte(DATA__rom0000)
Repeat:
    jmp endSongInstruction
Done:
    jmp endSongInstructionWithParameter
.endproc


.proc endSongInstructionWithParameter
    incw hl
    jmp endSongInstruction
.endproc


.proc endSongInstruction
    mov Y, #0
    mov A, [hl]+Y
    ret

; Where the two $F1 forms rejoin: A is the option byte with its top bits
; masked off, and that is the channel's effect index.
;
; The Game Boy's own "if A is not zero, set A to zero" is dead code -- M2RoS
; marks the branch `badCode` -- and is transcribed as the store it amounts to.
effectIndex:
    mov V__state_working + STATE__effectIndex, A
    jmp endSongInstructionWithParameter
.endproc


; ---------------------------------------------------------------------------
; handleSongSoundChannelEffect (M2RoS bank_004.asm:2042)
; ---------------------------------------------------------------------------
;
; bc = the channel's current frequency. Leaves the working frequency bent by
; whatever the channel's effect index asks for: a table-driven wobble, or a
; slide by a fixed step.
;
; The table index is a timer that counts $10 down from $11 and is shared by all
; four channels, so table N's index $10 reads table N+1's first byte. That is
; the Game Boy's behaviour, and the tables are contiguous in ARAM so it stays.
; Table $A's reads the byte after the last table, which `aram_layout.overreads`
; places.
.proc handleSongSoundChannelEffect
    mov A, V__state_working + STATE__effectIndex
    cmp A, #$02
    beq Index2
    cmp A, #$03
    beq Index3
    cmp A, #$04
    beq Index4
    cmp A, #$06
    beq Index6
    cmp A, #$07
    bne NotIndex7
    jmp Index7
NotIndex7:
    cmp A, #$08
    bne NotIndex8
    jmp Index8
NotIndex8:
    cmp A, #$09
    beq Index9
    cmp A, #$0a
    beq IndexA
    ret

Index2:
    mov hl.l, #lobyte(DATA__effectTable_index2)
    mov hl.h, #hibyte(DATA__effectTable_index2)
    bra Merge
Index3:
    mov hl.l, #lobyte(DATA__effectTable_index3)
    mov hl.h, #hibyte(DATA__effectTable_index3)
    bra Merge
Index4:
    mov hl.l, #lobyte(DATA__effectTable_index4)
    mov hl.h, #hibyte(DATA__effectTable_index4)
    bra Merge
Index9:
    mov hl.l, #lobyte(DATA__effectTable_index9)
    mov hl.h, #hibyte(DATA__effectTable_index9)
    bra Merge
IndexA:
    mov hl.l, #lobyte(DATA__effectTable_indexA)
    mov hl.h, #hibyte(DATA__effectTable_indexA)

Merge:
    mov A, V__songSoundChannelEffectTimer
    cmp A, #0
    bne TimerRunning
    mov A, #$11
    mov V__songSoundChannelEffectTimer, A
TimerRunning:
    dec A
    mov V__songSoundChannelEffectTimer, A

    mov de.l, A
    mov de.h, #0
    movw YA, hl
    addw YA, de
    movw hl, YA
    mov Y, #0
    mov A, [hl]+Y
    mov de.l, A
    mov de.h, #0
    movw YA, bc
    addw YA, de
    movw hl, YA
    mov A, hl.l
    mov V__songFrequency_working, A
    mov A, hl.h
    and A, #%0011_1111          ; res 7, res 6
    mov V__songFrequency_working + 1, A
    ret

Index6:
    incw bc
    mov A, bc.l
    mov V__songFrequency_working, A
    mov A, bc.h
    and A, #%0011_1111
    mov V__songFrequency_working + 1, A
SetFrequency:
    mov A, V__workingSoundChannel
    cmp A, #$01
    bne NotSquare1
    mov A, V__songFrequency_working
    mov V__songFrequency_square1, A
    mov A, V__songFrequency_working + 1
    mov V__songFrequency_square1 + 1, A
    ret
NotSquare1:
    cmp A, #$02
    bne NotSquare2
    mov A, V__songFrequency_working
    mov V__songFrequency_square2, A
    mov A, V__songFrequency_working + 1
    mov V__songFrequency_square2 + 1, A
    ret
NotSquare2:
    cmp A, #$03
    beq IsWave
    ret
IsWave:
    mov A, V__songFrequency_working
    mov V__songFrequency_wave, A
    mov A, V__songFrequency_working + 1
    and A, #%0111_1111          ; res 7
    mov V__songFrequency_wave + 1, A
    ret

Index7:
    incw bc
    incw bc
    incw bc
    incw bc
    mov A, bc.l
    mov V__songFrequency_working, A
    mov A, bc.h
    and A, #%0011_1111
    mov V__songFrequency_working + 1, A
    bra SetFrequency

Index8:
    decw bc
    decw bc
    decw bc
    mov A, bc.l
    mov V__songFrequency_working, A
    mov A, bc.h
    and A, #%0011_1111
    mov V__songFrequency_working + 1, A
    bra SetFrequency
.endproc
