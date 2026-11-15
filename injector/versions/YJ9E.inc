; DS-10 YJ9E: addresses found by find_addresses.py from the EU ROM
GAME_CODE       equ "YJ9E"
FS_InitFile          equ 0x02008928
FS_OpenFile          equ 0x02008c08
FS_CloseFile         equ 0x02008c50
FS_ReadFile          equ 0x02008d4c
SYNTH_RENDER         equ 0x020219b8
SAMPLE_RENDER        equ 0x02023968
SAMPLE_EVENTS        equ 0x02023a90
EDITSTAGE_RENDER     equ 0x02024578
HOOK_LEAVE_EDITOR    equ 0x0205f06c
HOOK_SONG_LOAD       equ 0x02033194
HOOK_KNOB_STORE      equ 0x02032910
HOOK_END_CLAMP       equ 0x02023a1c
VT_SYNTH_RENDER      equ 0x02072f7c
VT_SAMPLE_RENDER     equ 0x02072fe4
VT_SAMPLE_EVENTS     equ 0x02072ffc
VT_EDITSTAGE_RENDER  equ 0x02073090
EDIT_SESSION         equ 0x00000428
EDIT_AUDIO           equ 0x0000042c
ENV_MAX         equ 0x00b33333
ITCM_SRC        equ 0x02076f40      ; ITCM autoload data in arm9.bin (RAM address)
ITCM_DEST       equ 0x01ff8000
ITCM_OLD_SIZE   equ 0x320
