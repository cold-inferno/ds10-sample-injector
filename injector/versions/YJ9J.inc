; DS-10 YJ9J: addresses found by find_addresses.py from the EU ROM
GAME_CODE       equ "YJ9J"
FS_InitFile          equ 0x020088a4
FS_OpenFile          equ 0x02008b84
FS_CloseFile         equ 0x02008bcc
FS_ReadFile          equ 0x02008cc8
SYNTH_RENDER         equ 0x02021934
SAMPLE_RENDER        equ 0x020238e4
SAMPLE_EVENTS        equ 0x02023a0c
EDITSTAGE_RENDER     equ 0x020244f4
HOOK_LEAVE_EDITOR    equ 0x0205d284
HOOK_SONG_LOAD       equ 0x020320ec
HOOK_KNOB_STORE      equ 0x02031868
HOOK_END_CLAMP       equ 0x02023998
VT_SYNTH_RENDER      equ 0x020703fc
VT_SAMPLE_RENDER     equ 0x02070464
VT_SAMPLE_EVENTS     equ 0x0207047c
VT_EDITSTAGE_RENDER  equ 0x02070510
EDIT_SESSION         equ 0x0000039c
EDIT_AUDIO           equ 0x000003a0
ENV_MAX         equ 0x00b33333
ITCM_SRC        equ 0x02074400      ; ITCM autoload data in arm9.bin (RAM address)
ITCM_DEST       equ 0x01ff8000
ITCM_OLD_SIZE   equ 0x320
