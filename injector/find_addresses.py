"""Find every address the sample patch needs in another DS-10 version, using the EU ROM as reference.

Usage:
    python3 find_addresses.py <reference EU .nds> <target .nds> [out.inc]

Each symbol is located by the instruction pattern around it in the EU ARM9 code. Branch offsets and
PC-relative literal offsets are masked, since those change when code moves. Vtable entries are found
as the data word that points to the translated function. Writes an armips include with the
version's addresses (default: print it).
"""
import struct
import sys

RAM = 0x02000000

# name: (EU address, bytes before, bytes after). Hook sites sit in the middle of their window,
# function entries at the start.
SYMBOLS = {
    "FS_InitFile":          (0x02008928, 0, 48),
    "FS_OpenFile":          (0x02008C08, 0, 48),
    "FS_CloseFile":         (0x02008C50, 0, 48),
    "FS_ReadFile":          (0x02008D4C, 0, 48),
    "SYNTH_RENDER":         (0x020219B8, 0, 64),
    "SAMPLE_RENDER":        (0x02023968, 0, 64),
    "SAMPLE_EVENTS":        (0x02023A90, 0, 64),
    "EDITSTAGE_RENDER":     (0x02024578, 0, 64),
    "HOOK_LEAVE_EDITOR":    (0x0205F02C, 32, 32),
    "HOOK_SONG_LOAD":       (0x02033194, 32, 32),
    "HOOK_KNOB_STORE":      (0x02032910, 24, 32),   # JP: the editor object's fields shift
    "HOOK_END_CLAMP":       (0x02023A1C, 32, 32),
}
# vtable entry -> the function symbol it points to
VTABLE_ENTRIES = {
    "VT_SYNTH_RENDER":      (0x02072FDC, "SYNTH_RENDER"),
    "VT_SAMPLE_RENDER":     (0x02073044, "SAMPLE_RENDER"),
    "VT_SAMPLE_EVENTS":     (0x0207305C, "SAMPLE_EVENTS"),
    "VT_EDITSTAGE_RENDER":  (0x020730F0, "EDITSTAGE_RENDER"),
}
ENV_MAX_LITERAL = 0x02023A88            # literal load in SAMPLE_RENDER holding the envelope's full level


def arm9_of(path):
    d = open(path, "rb").read()
    off, entry, ram, size = struct.unpack("<IIII", d[0x20:0x30])
    return d, d[off:off + size], ram


def masked(words):
    """Per 32-bit word: (value, mask). Branch offsets, PC-relative literal offsets and literal
    words holding a main-RAM address are masked."""
    out = []
    for w in words:
        mask = 0xFFFFFFFF
        if (w >> 25) & 7 == 0b101:                              # B / BL: 24-bit offset
            mask = 0xFF000000
        elif (w & 0x0E5F0000) == 0x041F0000:                    # LDR/STR rX, [pc, #imm12]
            mask = 0xFFFFF000
        elif 0x02000000 <= w < 0x02400000:                      # literal: an address in main RAM
            mask = 0
        out.append((w & mask, mask))
    return out


def find(ref, target, ram_ref, ram_tgt, addr, before, after):
    o = addr - ram_ref - before
    words = struct.unpack(f"<{(before + after) // 4}I", ref[o:o + before + after])
    pat = masked(words)
    tw = struct.unpack(f"<{len(target) // 4}I", target[:len(target) // 4 * 4])
    anchor = next(k for k, (v, m) in enumerate(pat) if m == 0xFFFFFFFF and v not in (0, 0xE1A00000))
    hits = []
    av = pat[anchor][0]
    for i in range(anchor, len(tw) - len(pat) + anchor + 1):
        if tw[i] != av:
            continue
        s = i - anchor
        if all((tw[s + k] & m) == v for k, (v, m) in enumerate(pat)):
            hits.append(ram_tgt + s * 4 + before)
    return hits


def main():
    ref_path, tgt_path = sys.argv[1:3]
    rd, ref, ram_ref = arm9_of(ref_path)
    td, tgt, ram_tgt = arm9_of(tgt_path)
    code = td[12:16].decode()
    found = {}
    for name, (addr, before, after) in SYMBOLS.items():
        hits = find(ref, tgt, ram_ref, ram_tgt, addr, before, after)
        if len(hits) != 1:
            raise SystemExit(f"{code}: {name} found {len(hits)} times {[hex(h) for h in hits]}")
        found[name] = hits[0]
    for name, (addr, func) in VTABLE_ENTRIES.items():
        want = found[func]
        words = [ram_tgt + i for i in range(0, len(tgt) - 3, 4) if struct.unpack("<I", tgt[i:i + 4])[0] == want]
        if len(words) != 1:
            raise SystemExit(f"{code}: {name} (pointer to {want:#x}) found {len(words)} times")
        found[name] = words[0]
    # The drum editor object's layout differs between versions (JP: fields 0x8C lower). Read the two
    # fields the patch uses from the knob handler itself: "ldr r1, [r4, #session]" 0x1C before the
    # hook and "ldr r0, [r4, #audio object]" 0x5C before it.
    def ldr_imm(addr, rd):
        w = struct.unpack("<I", tgt[addr - ram_tgt:addr - ram_tgt + 4])[0]
        if (w & 0xFFFFF000) != (0xE5940000 | (rd << 12)):
            raise SystemExit(f"{code}: unexpected instruction {w:08x} at {addr:#x}")
        return w & 0xFFF
    found["EDIT_SESSION"] = ldr_imm(found["HOOK_KNOB_STORE"] - 0x1C, 1)
    found["EDIT_AUDIO"] = ldr_imm(found["HOOK_KNOB_STORE"] - 0x5C, 0)
    lit = ENV_MAX_LITERAL - ram_ref + (found["SAMPLE_RENDER"] - 0x02023968) - (ram_tgt - ram_ref)
    env_max = struct.unpack("<I", tgt[lit:lit + 4])[0]
    # ITCM autoload layout from the module params
    mp = tgt.find(struct.pack("<II", 0xDEC00621, 0x2106C0DE)) - 28
    list_start, list_end, auto_start = struct.unpack("<III", tgt[mp:mp + 12])
    itcm_dest, itcm_size, _ = struct.unpack("<III", tgt[list_start - ram_tgt:list_start - ram_tgt + 12])
    lines = [f"; DS-10 {code}: addresses found by find_addresses.py from the EU ROM",
             f"GAME_CODE       equ \"{code}\""]
    for name, val in found.items():
        lines.append(f"{name:<20s} equ {val:#010x}")
    lines += [f"ENV_MAX         equ {env_max:#010x}",
              f"ITCM_SRC        equ {auto_start:#010x}      ; ITCM autoload data in arm9.bin (RAM address)",
              f"ITCM_DEST       equ {itcm_dest:#010x}",
              f"ITCM_OLD_SIZE   equ {itcm_size:#x}"]
    text = "\n".join(lines) + "\n"
    if len(sys.argv) > 3:
        open(sys.argv[3], "w").write(text)
    print(text)


if __name__ == "__main__":
    main()
