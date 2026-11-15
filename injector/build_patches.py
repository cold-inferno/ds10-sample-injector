"""Assemble the sample patch for every supported DS-10 version and write the byte edits as JSON.

Usage:
    python3 build_patches.py

For each versions/<code>.inc it takes that version's ROM from ../ROMZ, grows the ARM9's ITCM
autoload block (the same way the injector page does), assembles ../rom-patch/patch_lib.asm with
armips, and records which bytes changed. The page applies those edits; it has no assembler.
Output: patches.json = {code: {crc32 of the original ARM9, ITCM layout, edits}}.
"""
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROMZ = os.path.join(HERE, "..", "ROMZ")
ARMIPS = os.path.join(HERE, "..", "rom-patch", "bin", "armips")
PATCH = os.path.join(HERE, "..", "rom-patch", "patch_lib.asm")
RAM = 0x02000000
ITCM_GROW = 0x2000
MODPARAMS_MAGIC = struct.pack("<II", 0xDEC00621, 0x2106C0DE)


def inc_values(path):
    vals = {}
    for line in open(path):
        m = re.match(r"(\w+)\s+equ\s+(0x[0-9a-fA-F]+|\"\w+\")", line)
        if m:
            v = m.group(2)
            vals[m.group(1)] = v.strip('"') if v.startswith('"') else int(v, 16)
    return vals


def rom_for(code):
    for f in sorted(os.listdir(ROMZ)):
        if f.endswith(".nds"):
            with open(os.path.join(ROMZ, f), "rb") as fh:
                if fh.read(16)[12:16].decode() == code:
                    return os.path.join(ROMZ, f)
    raise SystemExit(f"no ROM for {code} in ROMZ")


def arm9_with_footer(rom):
    off, _, ram, size = struct.unpack("<IIII", rom[0x20:0x30])
    footer = rom[off + size:off + size + 12]
    return rom[off:off + size], footer if footer[:4] == struct.pack("<I", 0xDEC00621) else b"", ram


def grow_itcm(arm9, v):
    """Insert ITCM_GROW zero bytes after the ITCM autoload data and fix the module params.
    Must match growItcm() in injector.js."""
    a = bytearray(arm9)
    mp = a.find(MODPARAMS_MAGIC) - 28
    list_start, list_end, auto_start = struct.unpack_from("<III", a, mp)
    assert auto_start == v["ITCM_SRC"], (hex(auto_start), hex(v["ITCM_SRC"]))
    dest, size, _ = struct.unpack_from("<III", a, list_start - RAM)
    assert (dest, size) == (v["ITCM_DEST"], v["ITCM_OLD_SIZE"])
    cut = auto_start + size - RAM
    a[cut:cut] = bytes(ITCM_GROW)
    struct.pack_into("<II", a, mp, list_start + ITCM_GROW, list_end + ITCM_GROW)
    struct.pack_into("<I", a, list_start + ITCM_GROW - RAM + 4, size + ITCM_GROW)
    return bytes(a)


def main():
    out = {}
    for inc in sorted(os.listdir(os.path.join(HERE, "versions"))):
        if not inc.endswith(".inc"):
            continue
        v = inc_values(os.path.join(HERE, "versions", inc))
        code = v["GAME_CODE"]
        rom = open(rom_for(code), "rb").read()
        arm9, footer, ram = arm9_with_footer(rom)
        assert ram == RAM
        grown = grow_itcm(arm9 + footer, v)
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "build"))
            with open(os.path.join(tmp, "build", "arm9.bin"), "wb") as f:
                f.write(grown)
            shutil.copy(os.path.join(HERE, "versions", inc), os.path.join(tmp, "build", "version.inc"))
            shutil.copy(PATCH, os.path.join(tmp, "patch_lib.asm"))
            subprocess.run([ARMIPS, "-equ", "DEBUG", "0", "patch_lib.asm"], check=True, cwd=tmp)
            patched = open(os.path.join(tmp, "build", "arm9.bin"), "rb").read()
        room = (v["ITCM_SRC"] + v["ITCM_OLD_SIZE"] - RAM, v["ITCM_SRC"] + v["ITCM_OLD_SIZE"] - RAM + ITCM_GROW)
        assert len(patched) == len(grown) and patched[room[1]:] == grown[room[1]:], "code outgrew the ITCM room"
        edits, i = [], 0
        while i < len(grown):                       # contiguous runs of changed bytes
            if patched[i] == grown[i]:
                i += 1
                continue
            j = i
            while j < len(grown) and (patched[j] != grown[j] or patched[j:j + 16] != grown[j:j + 16]):
                j += 1
            edits.append([i, patched[i:j].hex()])
            i = j
        used = len(patched[room[0]:room[1]].rstrip(b"\0"))
        out[code] = {
            "arm9Crc32": zlib.crc32(arm9) & 0xFFFFFFFF,
            "arm9Size": len(arm9),
            "itcmSrc": v["ITCM_SRC"], "itcmOldSize": v["ITCM_OLD_SIZE"], "itcmGrow": ITCM_GROW,
            "edits": edits,
        }
        print(f"{code}: {len(edits)} edits, {sum(len(h) // 2 for _, h in edits)} bytes, ITCM code {used:#x}, "
              f"arm9 crc32 {out[code]['arm9Crc32']:08x}")
    with open(os.path.join(HERE, "patches.json"), "w") as f:
        json.dump(out, f, indent=1)
    print("wrote patches.json")


if __name__ == "__main__":
    main()
