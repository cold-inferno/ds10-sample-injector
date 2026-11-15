; Korg DS-10 sample-library patch (armips).
;
; Same hook as patch.asm (both CopyToSlot calls go to LoadSlot), but each drum picks one of
; 128 samples from /data/smp/NNN.pcm using its own patch knobs:
;
;   n = VCO1 wave*32 + VCO2 wave*8 + sync*4 + (VCO2 pitch >= 0)*2 + (balance >= 64) + 1
;
; File format: 4-byte header, then up to 32768 samples.
;   byte 0: 0 = s16le, 1 = s8     byte 1: 1 = loop     bytes 2-3: loop start (sample index)
;   A looped sample loops from its loop start to its last sample.
; Missing file or short sample: the rest of the slot is silence.

.nds
.open "build/arm9.bin", 0x02000000

; Version-specific addresses (FS_*, HOOK_*, VT_*, *_RENDER, SAMPLE_EVENTS, EDIT_SESSION, EDIT_AUDIO,
; ENV_MAX, ITCM_*), written by injector/find_addresses.py for the ROM being patched.
.include "build/version.inc"
; FS_OpenFile (FSFile*, const char* path) -> bool; FS_ReadFile (FSFile*, void* dst, s32 len) -> s32

SLOT_BYTES      equ 0x10000
FSFILE_STACK    equ 0x60            ; FSFile is 0x48 bytes in this SDK; keep some slack

; Slot n is at base + 0x5F10 + n*0x10000, drum patch n at base + 0x5AA8 + n*31.
PATCH_FROM_SLOT equ 0x5F10 - 0x5AA8 ; = 0x468
P_VCO1_WAVE     equ 6
P_VCO2_WAVE     equ 7
P_VCO2_PITCH    equ 8               ; signed, -63..63
P_BALANCE       equ 9               ; 0..127
P_SYNC          equ 10

.headersize 0x02000000
.org HOOK_LEAVE_EDITOR              ; leaving drum edit: drum index in r6
    bl      LoadSlotFromR6
.org HOOK_SONG_LOAD                 ; song load, loop over drums: drum index in r9
    bl      LoadSlotFromR9
.org HOOK_KNOB_STORE                ; drum editor knob handler: was strb r6, [r0, 0xAA8]
    bl      DrumParamChanged
.org VT_SYNTH_RENDER                ; synth voice vtable, entry 3 (render)
    .word   SynthVoiceRender
.org VT_EDITSTAGE_RENDER            ; drum editor end stage vtable, entry 3 (render)
    .word   EditStageRender
.org HOOK_END_CLAMP                 ; sample voice render loop: end-of-sample clamp (5 insns)
    bl      LoopCheck
    nop
    nop
    nop
    nop
.org VT_SAMPLE_RENDER               ; sample voice vtable, entry 3 (render)
    .word   SampleVoiceRender
.if DEBUG
.org VT_SAMPLE_EVENTS               ; sample voice vtable, entry 9 (events): log every event
    .word   DbgSampleVoiceEvents
.endif

P_EG_ATTACK     equ 20              ; drum patch: EG ATT = fade-in time of a looped sample
P_EG_DECAY      equ 21              ; drum patch: EG DEC = fade-out time of a looped sample
P_EG_SUSTAIN    equ 22              ; drum patch: EG SUS = hold time (127 = forever)
HOLD_BLOCKS     equ 51              ; per sustain step: 51 blocks of 64 samples = 0.1 s
FADE_BLOCKS     equ 16              ; per decay step: 16 blocks = 31 ms (127 -> 4 s)
ATTACK_BLOCKS   equ 16              ; per attack step: the same scale
; Audio object ("M"): +0x13C editor preview sequencer, +0x14C drum sample voices,
; +0x170 session base, +0x190 mode (2 = drum editor).
M_PREVIEW_SEQ   equ 0x13C
M_DRUM_VOICES   equ 0x14C
M_SESSION       equ 0x170
M_EDIT_STAGE    equ 0x160           ; drum editor end stage (mixer source while editing)
M_MIXER         equ 0x140           ; mixer: +0x24/+0x28 and +0x2C/+0x30 = the two halves of the
                                    ; hardware's L/R output rings (SPU channels 0/1 play them)
M_MODE          equ 0x190
MODE_DRUM_EDIT  equ 2
; Voice events: 8 bytes {u8 type, ...; +4 s8 note, +5 velocity}. Same for synth and sample voices.
EV_NOTE_ON      equ 2

.headersize ITCM_DEST - (ITCM_SRC - 0x02000000)
.org ITCM_DEST + ITCM_OLD_SIZE
.arm
LoadSlotFromR6:                     ; leaving drum edit: r4 = audio object
    ldr     r12, =AudioObject
    str     r4, [r12]
    mov     r3, r6
    b       LoadSlot
LoadSlotFromR9:                     ; song load: r10 = audio object
    ldr     r12, =AudioObject
    str     r10, [r12]
    mov     r3, r9

; r1 = slot buffer, r3 = drum index 0..3. Returns 0 like the original copy routine.
LoadSlot:
    push    {r4-r8, lr}
    sub     sp, sp, FSFILE_STACK
    mov     r4, r1                      ; r4 = slot
    ; r6 = this drum's patch
    sub     r6, r4, r3, lsl 16
    sub     r6, r6, 0x400
    sub     r6, r6, PATCH_FROM_SLOT - 0x400
    rsb     r0, r3, r3, lsl 5           ; r3 * 31
    add     r6, r6, r0
    ; r7 = sample number 1..128
    ldrb    r0, [r6, P_VCO1_WAVE]
    and     r0, r0, 3
    mov     r7, r0, lsl 5
    ldrb    r0, [r6, P_VCO2_WAVE]
    and     r0, r0, 3
    add     r7, r7, r0, lsl 3
    ldrb    r0, [r6, P_SYNC]
    and     r0, r0, 1
    add     r7, r7, r0, lsl 2
    ldrsb   r0, [r6, P_VCO2_PITCH]
    cmp     r0, 0
    addge   r7, r7, 2
    ldrb    r0, [r6, P_BALANCE]
    cmp     r0, 64
    addge   r7, r7, 1
    add     r7, r7, 1
    ; write three digits into the path
    ldr     r8, =SamplePath
    mov     r0, '0'
@@hundreds:
    cmp     r7, 100
    subge   r7, r7, 100
    addge   r0, r0, 1
    bge     @@hundreds
    strb    r0, [r8, SampleDigits - SamplePath]
    mov     r0, '0'
@@tens:
    cmp     r7, 10
    subge   r7, r7, 10
    addge   r0, r0, 1
    bge     @@tens
    strb    r0, [r8, SampleDigits - SamplePath + 1]
    add     r0, r7, '0'
    strb    r0, [r8, SampleDigits - SamplePath + 2]

    mov     r5, 0                       ; r5 = bytes of the slot filled so far
    mov     r6, 0                       ; r6 = loop start + 1 (0 = no loop / no file)
    mov     r0, sp
    bl      FS_InitFile
    mov     r0, sp
    mov     r1, r8
    bl      FS_OpenFile
    cmp     r0, 0
    beq     @@silence
    mov     r0, sp                      ; header -> start of slot (overwritten below)
    mov     r1, r4
    mov     r2, 4
    bl      FS_ReadFile
    ldrb    r6, [r4, 1]                 ; r6 = loop start + 1, or 0 for no loop
    cmp     r6, 0
    ldrneh  r6, [r4, 2]
    addne   r6, r6, 1
    ldrb    r7, [r4]
    cmp     r7, 1
    beq     @@eightbit
    mov     r0, sp                      ; 16-bit: straight into the slot
    mov     r1, r4
    mov     r2, SLOT_BYTES
    bl      FS_ReadFile
    cmp     r0, 0
    movgt   r5, r0
    b       @@close
@@eightbit:
    mov     r0, sp                      ; 8-bit: into the upper half, then widen in place
    add     r1, r4, SLOT_BYTES / 2
    mov     r2, SLOT_BYTES / 2
    bl      FS_ReadFile
    cmp     r0, 0
    ble     @@close
    mov     r5, r0, lsl 1
    add     r2, r4, SLOT_BYTES / 2
    mov     r1, r4
@@widen:                                ; dst 2i stays below src i + 0x8000, so this is safe
    ldrsb   r3, [r2], 1
    mov     r3, r3, lsl 8
    strh    r3, [r1], 2
    subs    r0, r0, 1
    bgt     @@widen
@@close:
    mov     r0, sp
    bl      FS_CloseFile
@@silence:                              ; zero from r5 to the end of the slot
    ; Loop table entry for this slot: {loop length << 15, end in samples}, or zeros.
    ldr     r12, =LoopTable
    mov     r0, r4, lsr 16
    and     r0, r0, 3                   ; the 4 slots are 64 KB apart: unique mod 4
    add     r12, r12, r0, lsl 3
    mov     r0, 0
    str     r0, [r12, 4]                ; no loop until proven otherwise
    subs    r6, r6, 1                   ; loop start, or -1
    blt     @@noloop
    mov     r1, r5, lsr 1               ; end = samples in the slot
    sub     r2, r1, r6                  ; loop length
    cmp     r2, 2
    blt     @@noloop
    mov     r2, r2, lsl 15
    str     r2, [r12]
    str     r1, [r12, 4]
@@noloop:
    bic     r5, r5, 3
    mov     r0, 0
@@zero:
    cmp     r5, SLOT_BYTES
    strlt   r0, [r4, r5]
    addlt   r5, r5, 4
    blt     @@zero
    ; Looped: put the loop's first sample just past its end, so interpolating across the wrap
    ; (any note other than 60) doesn't dip towards the silence after the sample.
    ldr     r1, [r12, 4]                ; loop end, 0 = none
    cmp     r1, 0
    beq     @@done
    cmp     r1, SLOT_BYTES / 2
    bge     @@done
    ldr     r2, [r12]
    sub     r2, r1, r2, lsr 15          ; loop start
    add     r2, r4, r2, lsl 1
    ldrsh   r3, [r2]
    add     r2, r4, r1, lsl 1
    strh    r3, [r2]
@@done:
    mov     r0, 0
    add     sp, sp, FSFILE_STACK
    pop     {r4-r8, pc}

; Drum editor: a knob changed. In the original code: r0 + 0xAA8 = patch byte, r5 = param index,
; r6 = new value, r4 = editor object ([r4+EDIT_SESSION] = session base, [r4+EDIT_AUDIO] = audio
; object; 0x428/0x42C in EU and US, 0x39C/0x3A0 in JP).
; Store the value as before; if it is one of the 5 selector controls, load the newly selected
; sample into the edited drum's slot (the editor's own repeating preview then plays it).
DrumParamChanged:
    strb    r6, [r0, 0xAA8]
    cmp     r5, P_VCO1_WAVE
    bxlt    lr
    cmp     r5, P_SYNC
    bxgt    lr
    push    {r4-r6, lr}
    ldr     r0, [r4, EDIT_AUDIO]        ; audio object
    ldr     r12, =AudioObject
    str     r0, [r12]
    ldr     r1, [r4, EDIT_SESSION]      ; session base
    add     r0, r1, 0x45000
    ldr     r6, [r0, 0xF18]             ; edited drum 0..3
    add     r1, r1, 0x5F00
    add     r1, r1, 0x10
    add     r1, r1, r6, lsl 16          ; its slot
    mov     r3, r6
    bl      LoadSlot
    pop     {r4-r6, pc}

; Synth voice render (vtable hook). In the drum editor, the DS-10 previews the edited drum on
; synth voice 1, retriggered by its own little sequencer. The game still renders all four drum
; sample voices every block (measured with the debug counters), into channels the editor mutes.
; For the preview voice only: forward each note-on to the edited drum's sample voice and render
; the synth as usual (keeps its state). EditStageRender then puts the sample voice's sound out.
SynthVoiceRender:
    push    {r4-r6, lr}
    mov     r4, r0
.if DEBUG
    mov     r0, 0x10                    ; mark: any synth voice render
    bl      DbgMark
.endif
    ldr     r5, =AudioObject
    ldr     r5, [r5]
    cmp     r5, 0
    beq     @@plain
    ldr     r0, [r5, M_MODE]
    cmp     r0, MODE_DRUM_EDIT
    bne     @@plain
    ldr     r0, [r5, M_PREVIEW_SEQ]
    ldr     r0, [r0, 0x3C]
    ldr     r0, [r0, 0x18]              ; the preview's synth voice
    cmp     r0, r4
    bne     @@plain
    ldrb    r1, [r4, 8]                 ; any note-on (type 2) waiting for the synth?
    ldr     r2, [r4, 4]
    mov     r6, 0
@@scan:
    subs    r1, r1, 1
    blt     @@scanned
    ldrb    r3, [r2], 8
    cmp     r3, EV_NOTE_ON
    moveq   r6, 1
    b       @@scan
@@scanned:
.if DEBUG
    ldr     r2, =DbgSynthCalls
    ldr     r0, [r2]
    add     r0, r0, 1
    str     r0, [r2]
    ldr     r0, [r5, 0x164]             ; recorder
    ldr     r0, [r0, 0x28]              ; its write position
    ldr     r1, [r2, 8]                 ; DbgRecLast
    cmp     r0, r1
    strne   r0, [r2, 8]
    ldrne   r1, [r2, 4]                 ; DbgRecSteps
    addne   r1, r1, 1
    strne   r1, [r2, 4]
.endif
    ldr     r0, [r5, M_SESSION]
    add     r0, r0, 0x45000
    ldr     r3, [r0, 0xF18]             ; edited drum 0..3
    add     r0, r5, r3, lsl 2
    ldr     r5, [r0, M_DRUM_VOICES]     ; r5 = its sample voice
    cmp     r6, 0
    movne   r0, r5
    blne    PostNoteOn
    mov     r0, r4
    bl      SYNTH_RENDER                ; keeps the synth's state; its sound is replaced
    pop     {r4-r6, pc}
@@plain:
    mov     r0, r4
    pop     {r4-r6, lr}
    b       SYNTH_RENDER

; Drum editor end stage render (vtable hook). The stage turns synth 1's channel into the editor's
; stereo output, and fades each preview note out after one second (as long as a rendered drum
; would last), after which it stops rendering. Replace its output with the edited drum's sample
; voice block (the game renders that voice every block) so looped samples keep sounding; for the
; blocks the stage skips, see EditorOut. Same level as normal playback.
EditStageRender:
    push    {r4, lr}
    mov     r4, r0
.if DEBUG
    mov     r0, 0x20                    ; mark: end stage
    bl      DbgMark
    mov     r0, r4                      ; DbgMark used r0: give the original its object back
.endif
    bl      EDITSTAGE_RENDER
    mov     r0, r4
    pop     {r4, lr}
    ; fall through

; r0 = drum editor end stage. In the drum editor, put the edited drum's sample voice block into
; both channels of the stage's output (its output entry holds a left and a right buffer pointer).
PutPreview:
    push    {r4-r6, lr}
    mov     r4, r0
    ldr     r5, =AudioObject
    ldr     r5, [r5]
    cmp     r5, 0
    beq     @@out
    ldr     r0, [r5, M_MODE]
    cmp     r0, MODE_DRUM_EDIT
    bne     @@out
    ldr     r0, [r5, M_SESSION]
    add     r0, r0, 0x45000
    ldr     r3, [r0, 0xF18]             ; edited drum 0..3
    add     r0, r5, r3, lsl 2
    ldr     r5, [r0, M_DRUM_VOICES]     ; its sample voice
    ldr     r5, [r5, 0x1C]
    ldr     r5, [r5]                    ; sample voice's output buffer (source)
    ldr     r6, [r4, 0x1C]              ; stage output entry: {left, right}
    ldrsh   r1, [r4, 0x10]              ; samples per block
    ldr     r0, [r6]
    ldr     r6, [r6, 4]
    mov     r2, r5
@@copy:
    subs    r1, r1, 1
    blt     @@out
    ldrh    r3, [r2], 2
    strh    r3, [r0], 2
    strh    r3, [r6], 2
    b       @@copy
@@out:
    pop     {r4-r6, pc}

.if DEBUG
.pool
    .ascii  "DBG!"                      ; marker to find the counters in a savestate
DbgSynthCalls:  .word 0                 ; +0: preview synth renders
DbgRecSteps:    .word 0                 ; +4: times the recorder position changed
DbgRecLast:     .word 0                 ; +8
DbgOurs:        .word 0                 ; sample voice renders done by us
DbgGame:        .word 0                 ; ... by the game while in the drum editor
DbgInOurCall:   .word 0

; Log the events a drum sample voice is about to handle, then run the original handler.
; Counts per event type (0-31) for normal mode and drum-editor mode, and a ring of the
; last 16 events: {voice, word 0, word 1}.
DbgSampleVoiceEvents:
    push    {r0, r4-r7, lr}
    ldrb    r4, [r0, 8]                 ; queued events
    ldr     r5, [r0, 4]
    ldr     r6, =DbgEvCounts
    ldr     r1, =AudioObject
    ldr     r1, [r1]
    cmp     r1, 0
    ldrne   r1, [r1, M_MODE]
    cmp     r1, MODE_DRUM_EDIT
    addeq   r6, r6, 128                 ; editor counters follow the normal ones
@@ev:
    subs    r4, r4, 1
    blt     @@evdone
    ldrb    r1, [r5]
    and     r1, r1, 31
    ldr     r2, [r6, r1, lsl 2]
    add     r2, r2, 1
    str     r2, [r6, r1, lsl 2]
    ldr     r7, =DbgEvRing
    ldr     r1, [r7, 192]               ; ring index (after 16 entries of 12 bytes)
    add     r2, r1, r1, lsl 1           ; *3
    add     r2, r7, r2, lsl 2           ; *12
    str     r0, [r2]
    ldr     r3, [r5]
    str     r3, [r2, 4]
    ldr     r3, [r5, 4]
    str     r3, [r2, 8]
    add     r1, r1, 1
    and     r1, r1, 15
    str     r1, [r7, 192]
    add     r5, r5, 8
    b       @@ev
@@evdone:
    pop     {r0, r4-r7, lr}
    b       SAMPLE_EVENTS
.pool
; Append mark r0 to a 4096-entry timeline ring (keeps r1-r3, r12). Layout: index word, ring.
DbgMark:
    push    {r1-r3}
    ldr     r1, =DbgTimeline
    ldr     r2, [r1]                    ; next index
    add     r3, r1, 4
    strb    r0, [r3, r2]
    add     r2, r2, 1
    bic     r2, r2, 0xF000              ; wrap at 4096
    str     r2, [r1]
    pop     {r1-r3}
    bx      lr
.pool
    .ascii  "TML!"
DbgTimeline:    .fill 4100, 0
    .ascii  "EVT!"                      ; marker: counts[32] normal, counts[32] editor, ring
DbgEvCounts:    .fill 256, 0
DbgEvRing:      .fill 196, 0
.endif

; Sample voice render loop, replacing its end-of-sample clamp. In: r4 = voice, r5 = new position
; (16.15 fixed point, already stored at [r4+0x38]). May use r3, r5, r12; must keep r0-r2, r4.
LoopCheck:
    ldr     r3, [r4, 0x44]              ; slot
    mov     r3, r3, lsr 16
    and     r3, r3, 3
    ldr     r12, =LoopTable
    add     r12, r12, r3, lsl 3
    ldr     r3, [r12, 4]                ; loop end (samples), 0 = not looped
    cmp     r3, 0
    beq     @@clamp
    cmp     r5, r3, lsl 15
    bxlt    lr
    ldr     r3, [r12]                   ; loop length << 15
    sub     r5, r5, r3
    str     r5, [r4, 0x38]
    bx      lr
@@clamp:                                ; the original code: hold at the last sample
    ldr     r3, [r4, 0x40]
    sub     r3, r3, 2
    cmp     r3, r5, asr 15
    movlt   r3, r3, lsl 15
    strlt   r3, [r4, 0x38]
    bx      lr

LoopTable:                              ; per slot (index = (slot >> 16) & 3): length<<15, end
    .fill   32, 0

; Sample voice render (vtable hook), runs for every drum voice every block, also in the editor.
; Looped samples get a fade-in (EG ATT), a hold time (EG SUS, 127 = forever) and a fade-out
; (EG DEC), done by taking over the voice's envelope: state 2 leaves its level alone, and its
; "released" flag decides whether the next note-on restarts it.
SampleVoiceRender:
    push    {r4-r8, lr}
    mov     r4, r0
.if DEBUG
    ldr     r0, [r4, 0x44]
    mov     r0, r0, lsr 16
    and     r0, r0, 3
    orr     r0, r0, 0x30                ; mark: sample voice of slot 0-3
    bl      DbgMark
.endif
    bl      EnvSlot                     ; r7 = this voice's envelope state, r8 = loop entry
    mov     r5, 0                       ; a note-on waiting in the queue?
    ldrb    r1, [r4, 8]
    ldr     r2, [r4, 4]
@@scan:
    subs    r1, r1, 1
    blt     @@scanned
    ldrb    r3, [r2], 8
    cmp     r3, EV_NOTE_ON
    moveq   r5, 1
    b       @@scan
@@scanned:
    cmp     r5, 0
    beq     @@render
    mov     r0, 0                       ; note-on: restart attack, hold and fade
    str     r0, [r7]                    ; blocks since attack ended
    str     r0, [r7, 8]                 ; not fading
    str     r0, [r7, 12]                ; not attacking
    ldr     r0, [r8, 4]                 ; looped sample?
    cmp     r0, 0
    beq     @@render
    bl      DrumPatch
    cmp     r0, 0
    beq     @@render
    ldrb    r1, [r0, P_EG_ATTACK]
    cmp     r1, 0
    beq     @@render
    mov     r3, ATTACK_BLOCKS
    mul     r2, r1, r3
    ldr     r0, =ENV_MAX
    mov     r1, r2
    bl      DivideU
    add     r0, r0, 1
    str     r0, [r7, 12]                ; attack: level step per block
    ; The sequencer may queue a release (type 1, 5 or 25) for the previous hit in the same block;
    ; that would make the note-on restart the game's own envelope. The note-on restarts the
    ; sound anyway, so drop those releases.
    ldrb    r1, [r4, 8]
    ldr     r2, [r4, 4]
@@unrelease:
    subs    r1, r1, 1
    blt     @@unreleased
    ldrb    r3, [r2]
    cmp     r3, 1
    cmpne   r3, 5
    cmpne   r3, 25
    moveq   r3, 0
    streqb  r3, [r2]
    add     r2, r2, 8
    b       @@unrelease
@@unreleased:
    ldr     r6, [r4, 0x30]
    mov     r0, 2
    strb    r0, [r6, 0x10]              ; hands-off state; with "released" cleared, the note-on
    mov     r0, 0                       ; handler leaves it alone, so the sound starts silent
    strb    r0, [r6, 0x11]
    str     r0, [r6, 0x14]
@@render:
    mov     r0, r4
    bl      SAMPLE_RENDER
    bl      EditorOut                   ; drum editor: this block -> the output ring
    ldr     r0, [r8, 4]                 ; looped sample?
    cmp     r0, 0
    beq     @@done
    bl      DrumPatch                   ; r0 = this drum's patch, or 0
    cmp     r0, 0
    beq     @@done
    ldr     r6, [r4, 0x30]              ; envelope object: +0x10 state, +0x11 released, +0x14 level
    ldr     r1, [r7, 12]
    cmp     r1, 0
    beq     @@hold
    ldr     r2, [r6, 0x14]              ; attacking: ramp up to full level
    add     r2, r2, r1
    ldr     r3, =ENV_MAX
    cmp     r2, r3
    strlt   r2, [r6, 0x14]
    blt     @@done
    str     r3, [r6, 0x14]
    mov     r1, 0
    str     r1, [r7, 12]                ; attack done; the hold time starts now
    str     r1, [r7]
    mov     r1, 1
    strb    r1, [r6, 0x11]              ; "released", so the next note-on restarts the envelope
    b       @@done
@@hold:
    ldr     r1, [r7, 8]
    cmp     r1, 0
    bne     @@fading
    ldrb    r2, [r0, P_EG_SUSTAIN]
    cmp     r2, 127
    bge     @@done                      ; hold forever
    mov     r3, HOLD_BLOCKS
    mul     r1, r2, r3                  ; hold time in blocks
    ldr     r2, [r7]
    add     r2, r2, 1
    str     r2, [r7]
    cmp     r2, r1
    blt     @@done
    ldrb    r2, [r0, P_EG_DECAY]        ; hold is over: start the fade
    mov     r3, FADE_BLOCKS
    mul     r1, r2, r3
    add     r1, r1, 1                   ; fade length in blocks
    ldr     r0, [r6, 0x14]
    bl      DivideU                     ; r0 = level / blocks
    add     r0, r0, 1
    str     r0, [r7, 4]                 ; level step per block
    mov     r0, 1
    str     r0, [r7, 8]
    mov     r0, 2
    strb    r0, [r6, 0x10]
    mov     r0, 1
    strb    r0, [r6, 0x11]
@@fading:
    ldr     r0, [r6, 0x14]
    ldr     r1, [r7, 4]
    subs    r0, r0, r1
    movlt   r0, 0
    str     r0, [r6, 0x14]
@@done:
    pop     {r4-r8, pc}

; r4 = sample voice, just rendered. In the drum editor, if it is the edited drum's voice, copy its
; block into both channels of the half of the hardware's output ring that the mixer is filling in
; this block: mixer+0x16 is the half being played (the sound alarm toggles it every block), the
; mixer renders into the other one. The end stage, rendered after the voices, writes the same half
; and EditStageRender replaces that with this same block. But for 64 blocks before each preview
; note the mixer does not render the stage (it clears the stage's delay lines instead) and nothing
; else writes the ring, so the hardware would loop stale blocks: this copy covers those blocks.
; Uses r0-r3, r12.
EditorOut:
    ldr     r0, =AudioObject
    ldr     r0, [r0]
    cmp     r0, 0
    bxeq    lr
    ldr     r1, [r0, M_MODE]
    cmp     r1, MODE_DRUM_EDIT
    bxne    lr
    ldr     r1, [r0, M_SESSION]
    add     r1, r1, 0x45000
    ldr     r1, [r1, 0xF18]             ; edited drum 0..3
    add     r1, r0, r1, lsl 2
    ldr     r1, [r1, M_DRUM_VOICES]     ; its sample voice
    cmp     r1, r4
    bxne    lr
    ldr     r0, [r0, M_MIXER]
    ldrb    r1, [r0, 0x16]              ; half being played now
    eor     r1, r1, 1                   ; -> half the mixer fills in this block
    add     r0, r0, 0x24
    add     r0, r0, r1, lsl 3
    ldr     r12, [r0, 4]                ; right buffer
    ldr     r0, [r0]                    ; left buffer
    ldr     r2, [r4, 0x1C]
    ldr     r2, [r2]                    ; the voice's block (source)
    ldrsh   r1, [r4, 0x10]              ; samples per block
@@copy:
    subs    r1, r1, 1
    bxlt    lr
    ldrh    r3, [r2], 2
    strh    r3, [r0], 2
    strh    r3, [r12], 2
    b       @@copy

; r4 = sample voice -> r7 = its envelope state {blocks, fade step, fading, attack step},
; r8 = its loop entry.
; Both tables are indexed like LoopTable: (slot >> 16) & 3.
EnvSlot:
    ldr     r0, [r4, 0x44]
    mov     r0, r0, lsr 16
    and     r0, r0, 3
    ldr     r7, =EnvTable
    add     r7, r7, r0, lsl 4
    ldr     r8, =LoopTable
    add     r8, r8, r0, lsl 3
    bx      lr

; r4 = sample voice -> r0 = its drum's patch (session + 0x5AA8 + drum*31), or 0.
DrumPatch:
    ldr     r0, =AudioObject
    ldr     r0, [r0]
    cmp     r0, 0
    bxeq    lr
    ldr     r0, [r0, M_SESSION]
    ldr     r1, [r4, 0x44]              ; slot = session + 0x5F10 + drum * 0x10000
    sub     r1, r1, r0
    sub     r1, r1, 0x5F00
    sub     r1, r1, 0x10
    mov     r1, r1, lsr 16              ; drum 0..3
    cmp     r1, 3
    movhi   r0, 0
    bxhi    lr
    add     r0, r0, 0x5A00
    add     r0, r0, 0xA8
    rsb     r1, r1, r1, lsl 5           ; * 31
    add     r0, r0, r1
    bx      lr

; r0 / r1 (unsigned, r1 > 0) -> r0. Shift-and-subtract; only used once per fade.
DivideU:
    mov     r2, 0
    mov     r3, 1
@@align:
    cmp     r1, r0
    movls   r1, r1, lsl 1
    movls   r3, r3, lsl 1
    bls     @@align
@@sub:
    cmp     r0, r1
    subhs   r0, r0, r1
    addhs   r2, r2, r3
    movs    r3, r3, lsr 1
    movne   r1, r1, lsr 1
    bne     @@sub
    mov     r0, r2
    bx      lr

EnvTable:                               ; per slot: blocks since note-on, step, fading, -
    .fill   64, 0

AudioObject:                            ; captured at session load, editor exit and knob changes
    .word   0

; Queue a note-on (event type 2: note 60 = original pitch, velocity 127) on a sample voice.
; Same queue the game uses: entries of 8 bytes at [voice+4], count byte at [voice+8].
PostNoteOn:
    ldr     r12, =0x04000208            ; REG_IME: no interrupts while touching the queue
    ldrh    r2, [r12]
    mov     r3, 0
    strh    r3, [r12]
    ldrb    r1, [r0, 8]
    cmp     r1, 8                       ; don't overrun a queue nobody is draining
    bge     @@restore
    ldr     r3, [r0, 4]
    add     r3, r3, r1, lsl 3
    mov     r1, EV_NOTE_ON
    str     r1, [r3]
    ldr     r1, =0x7F3C                 ; byte 4 = note 60, byte 5 = velocity 127
    str     r1, [r3, 4]
    ldrb    r1, [r0, 8]
    add     r1, r1, 1
    strb    r1, [r0, 8]
@@restore:
    strh    r2, [r12]
    bx      lr
.pool

SamplePath:
    .ascii  "/data/smp/"
SampleDigits:
    .asciiz "001.pcm"
.align 4

.close
