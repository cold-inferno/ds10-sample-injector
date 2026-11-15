# DS-10 Sample Injector (development)

`dist/DS-10 Sample Injector.html` is the whole tool: one file, no install, runs in any modern browser.
The user drops in their own DS-10 ROM and WAVs and gets a patched ROM plus a cheat sheet as downloads.

## Supported versions

| Code | Game | ARM9 CRC32 | Notes |
|---|---|---|---|
| YJ9P | DS-10 Europe | `918269b6` | reference |
| YJ9E | DS-10 USA | `1bb5db88` | same code as EU, shifted |
| YJ9J | DS-10 Japan | `8e2e23c4` | same code; drum editor object fields 0x8C lower (EDIT_SESSION/EDIT_AUDIO) |

Recognised by game code + CRC32 of the ARM9, so header-variant dumps (e.g. "Goomba") work too.
DS-10+ (VKGE/VKGJ/VKPJ) is refused for now: compressed ARM9 at 0x02004000, an overlay, DSi ARM9i.

## Pipeline

1. `find_addresses.py <EU.nds> <target.nds> versions/<code>.inc`: finds every address the patch needs
   by the EU instruction pattern around it (branch offsets, PC-relative literals and absolute-address
   literals masked), vtable entries as the data word pointing to the translated function, and the
   drum editor object's field offsets from the knob handler.
2. `build_patches.py`: for each version, grows the ITCM by 0x2000 and assembles `../rom-patch/patch_lib.asm`
   with that version's `.inc`; records the changed bytes in `patches.json`.
3. `build_page.py`: inlines `src/core.js` and `patches.json` into `src/page.html` → `dist/`.

`../rom-patch/build_lib.py` uses the same `patch_lib.asm` + `versions/YJ9P.inc`.

## Tests (Node)

- `node test/test_rom.js`: EU via core.js vs the tested V1.1 ROM (ARM9, ARM7, banner, all 578 files).
- `node test/test_encode.js <dir>`: sample encoding vs build_lib.py (needs the python dump step).
- `node test/test_versions.js`: builds every ROM in ../ROMZ; writes test/out-<code>.nds.

Hardware check (2026-11-15): US and JP ROMs built with the page tested good (melonDS/DSi); EU is the V1.1 code.

Browser check (done 2026-11-15): the page's output for the V1.1 library had all 128 sample files
bit-identical to the Node encoding of the raw WAVs, and the ARM9 identical to V1.1.

## Notes

- The page keeps every original header field and only updates offsets, sizes, capacity and the header
  CRC. ndstool's rewrite of the ROM-control words was what stopped the R4 booting earlier ROMs.
- 16-bit 32768 Hz WAVs are read directly (bit-exact). Other audio goes through `decodeAudioData` at
  32768 Hz; Chrome scales positive samples by 1/32767 and negative by 1/32768, so the page undoes that.
