// DS-10 sample injector: ROM patching core. No DOM; runs in the browser and in Node (for tests).
// Ports of rom-patch/build_lib.py (sample encoding, loop fitting, INIT kit) and of the ndstool
// steps we need, except that the ROM is laid out again here while keeping every original header
// field (ndstool rewrote the ROM-control words, which some flashcarts refuse).
const DS10 = (() => {
  "use strict";

  const RAM = 0x02000000;
  const SLOT_SAMPLES = 32768;              // one drum slot: 1 s at 32768 Hz
  const ALIGN = 0x200;
  const MODPARAMS_MAGIC = [0x21, 0x06, 0xC0, 0xDE];   // 0xDEC00621 little-endian
  const INIT_DRUM_PATCHES = 0x2B3C;        // in ds10init.dat; 31 bytes per drum

  // ---------- checksums ----------
  const CRC32_TABLE = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(bytes) {
    let c = 0xFFFFFFFF;
    for (let i = 0; i < bytes.length; i++) c = CRC32_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
  function crc16(bytes) {                  // NDS header CRC (CRC-16/MODBUS)
    let c = 0xFFFF;
    for (let i = 0; i < bytes.length; i++) {
      c ^= bytes[i];
      for (let k = 0; k < 8; k++) c = c & 1 ? (c >>> 1) ^ 0xA001 : c >>> 1;
    }
    return c;
  }
  function md5(bytes) {                    // RFC 1321; used for the session checksum in ds10init.dat
    const K = new Uint32Array(64), S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
    for (let i = 0; i < 64; i++) K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0;
    const n = bytes.length, total = ((n + 8) >> 6) + 1 << 6;
    const m = new Uint8Array(total);
    m.set(bytes); m[n] = 0x80;
    const dv = new DataView(m.buffer);
    dv.setUint32(total - 8, (n * 8) >>> 0, true);
    dv.setUint32(total - 4, Math.floor(n / 0x20000000), true);
    let a0 = 0x67452301, b0 = 0xEFCDAB89, c0 = 0x98BADCFE, d0 = 0x10325476;
    for (let off = 0; off < total; off += 64) {
      let a = a0, b = b0, c = c0, d = d0;
      for (let i = 0; i < 64; i++) {
        let f, g;
        if (i < 16) { f = (b & c) | (~b & d); g = i; }
        else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) % 16; }
        else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
        else { f = c ^ (b | ~d); g = (7 * i) % 16; }
        const s = S[(i >> 4) * 4 + (i & 3)];
        const x = (a + f + K[i] + dv.getUint32(off + g * 4, true)) >>> 0;
        a = d; d = c; c = b;
        b = (b + ((x << s) | (x >>> (32 - s)))) >>> 0;
      }
      a0 = (a0 + a) >>> 0; b0 = (b0 + b) >>> 0; c0 = (c0 + c) >>> 0; d0 = (d0 + d) >>> 0;
    }
    const out = new Uint8Array(16), ov = new DataView(out.buffer);
    [a0, b0, c0, d0].forEach((w, i) => ov.setUint32(i * 4, w, true));
    return out;
  }

  // ---------- ROM structure ----------
  const u32 = (b, o) => (b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24) >>> 0;
  const u16 = (b, o) => b[o] | b[o + 1] << 8;
  const put32 = (b, o, v) => { b[o] = v & 255; b[o + 1] = v >>> 8 & 255; b[o + 2] = v >>> 16 & 255; b[o + 3] = v >>> 24 & 255; };
  const put16 = (b, o, v) => { b[o] = v & 255; b[o + 1] = v >>> 8 & 255; };
  const alignUp = (n, a = ALIGN) => Math.ceil(n / a) * a;
  const ascii = (b, o, n) => String.fromCharCode(...b.subarray(o, o + n)).replace(/\0+$/, "");

  function bannerSize(rom, off) {
    if (!off) return 0;
    return { 1: 0x840, 2: 0x940, 3: 0xA40, 0x103: 0x23C0 }[u16(rom, off)] || 0x840;
  }

  function parseFnt(fnt) {
    const ndirs = u16(fnt, 6);
    const dirs = [];
    for (let i = 0; i < ndirs; i++) {
      const sub = u32(fnt, i * 8), first = u16(fnt, i * 8 + 4), parent = u16(fnt, i * 8 + 6);
      const entries = [];
      let p = sub;
      for (;;) {
        const t = fnt[p++];
        if (!t) break;
        const len = t & 0x7F;
        const name = ascii(fnt, p, len); p += len;
        if (t & 0x80) { entries.push({ dir: true, name, id: u16(fnt, p) }); p += 2; }
        else entries.push({ dir: false, name });
      }
      dirs.push({ first, parent: i ? parent : 0xF000, entries });
    }
    return dirs;
  }

  function buildFnt(dirs) {
    const tables = dirs.map(d => {
      const out = [];
      for (const e of d.entries) {
        const nameBytes = [...e.name].map(ch => ch.charCodeAt(0));
        out.push((e.dir ? 0x80 : 0) | nameBytes.length, ...nameBytes);
        if (e.dir) out.push(e.id & 255, e.id >>> 8);
      }
      out.push(0);
      return out;
    });
    const main = dirs.length * 8;
    const size = main + tables.reduce((s, t) => s + t.length, 0);
    const fnt = new Uint8Array(size);
    let p = main;
    dirs.forEach((d, i) => {
      put32(fnt, i * 8, p);
      put16(fnt, i * 8 + 4, d.first);
      put16(fnt, i * 8 + 6, i ? d.parent : dirs.length);
      fnt.set(tables[i], p);
      p += tables[i].length;
    });
    return fnt;
  }

  function parseRom(rom) {
    const h = off => u32(rom, off);
    const code = ascii(rom, 12, 4);
    const arm9 = rom.subarray(h(0x20), h(0x20) + h(0x2C));
    const footerAt = h(0x20) + h(0x2C);
    const hasFooter = u32(rom, footerAt) === 0xDEC00621;
    const fnt = rom.subarray(h(0x40), h(0x40) + h(0x44));
    const fatOff = h(0x48), nfiles = h(0x4C) / 8;
    const files = [];
    for (let i = 0; i < nfiles; i++) files.push(rom.subarray(h(fatOff + i * 8), h(fatOff + i * 8 + 4)));
    return {
      rom, code, title: ascii(rom, 0, 12), headerSize: h(0x84),
      arm9, arm9Footer: hasFooter ? rom.subarray(footerAt, footerAt + 12) : new Uint8Array(0),
      arm9Ram: h(0x28),
      arm9Ovt: rom.subarray(h(0x50), h(0x50) + h(0x54)),
      arm7: rom.subarray(h(0x30), h(0x30) + h(0x3C)),
      arm7Ovt: rom.subarray(h(0x58), h(0x58) + h(0x5C)),
      banner: rom.subarray(h(0x68), h(0x68) + bannerSize(rom, h(0x68))),
      dirs: parseFnt(fnt), files,
    };
  }

  function findFile(p, path) {                    // "data/demo/ds10init.dat" -> file id
    const parts = path.split("/");
    let dir = 0;
    for (let i = 0; i < parts.length; i++) {
      const d = p.dirs[dir];
      let fileIdx = 0;
      let found = null;
      for (const e of d.entries) {
        if (e.name === parts[i]) { found = e; break; }
        if (!e.dir) fileIdx++;
      }
      if (!found) return -1;
      if (i === parts.length - 1) return found.dir ? -1 : d.first + fileIdx;
      if (!found.dir) return -1;
      dir = found.id & 0x0FFF;
    }
    return -1;
  }

  // ---------- patch ----------
  function identify(p, patches) {
    const v = patches[p.code];
    if (!v) return { ok: false, reason: `This isn't a supported DS-10 ROM (game code ${p.code || "?"}).` };
    if (p.arm9.length !== v.arm9Size || crc32(p.arm9) !== v.arm9Crc32)
      return { ok: false, reason: `This ${p.code} ROM's game code doesn't match the known DS-10 ${p.code}. Is it modified or already patched?` };
    return { ok: true, version: v };
  }

  function growItcm(arm9WithFooter, v) {          // must match grow_itcm() in build_patches.py
    const a = arm9WithFooter;
    let mp = -1;
    for (let i = 0; i + 8 <= a.length; i += 4)
      if (a[i] === MODPARAMS_MAGIC[0] && a[i + 1] === MODPARAMS_MAGIC[1] && a[i + 2] === MODPARAMS_MAGIC[2] &&
          a[i + 3] === MODPARAMS_MAGIC[3] && u32(a, i + 4) === 0x2106C0DE) { mp = i - 28; break; }
    if (mp < 0) throw new Error("module params not found");
    const listStart = u32(a, mp), listEnd = u32(a, mp + 4), autoStart = u32(a, mp + 8);
    if (autoStart !== v.itcmSrc || u32(a, listStart - RAM + 4) !== v.itcmOldSize) throw new Error("unexpected ITCM layout");
    const cut = autoStart + v.itcmOldSize - RAM;
    const out = new Uint8Array(a.length + v.itcmGrow);
    out.set(a.subarray(0, cut));
    out.set(a.subarray(cut), cut + v.itcmGrow);
    put32(out, mp, listStart + v.itcmGrow);
    put32(out, mp + 4, listEnd + v.itcmGrow);
    put32(out, listStart + v.itcmGrow - RAM + 4, v.itcmOldSize + v.itcmGrow);
    return out;
  }

  function patchArm9(p, v) {
    const a = new Uint8Array(p.arm9.length + p.arm9Footer.length);
    a.set(p.arm9); a.set(p.arm9Footer, p.arm9.length);
    const grown = growItcm(a, v);
    for (const [off, hex] of v.edits)
      for (let i = 0; i < hex.length / 2; i++) grown[off + i] = parseInt(hex.substr(i * 2, 2), 16);
    return { arm9: grown.subarray(0, grown.length - p.arm9Footer.length), footer: grown.subarray(grown.length - p.arm9Footer.length) };
  }

  // ---------- samples ----------
  // pcm: Int16Array at 32768 Hz. Returns {pcm, loopStart, shortened} like fit_loop() in build_lib.py.
  function fitLoop(pcm, start, end) {
    end = Math.min(end, pcm.length);
    const length = end - start;
    if (length < 2) return { pcm: pcm.subarray(0, SLOT_SAMPLES), loopStart: null, shortened: false };
    if (end <= SLOT_SAMPLES) return { pcm: pcm.subarray(0, end), loopStart: start, shortened: false };
    if (length <= SLOT_SAMPLES / 2) {
      const head = SLOT_SAMPLES - length, out = new Int16Array(SLOT_SAMPLES);
      out.set(pcm.subarray(0, head)); out.set(pcm.subarray(start, end), head);
      return { pcm: out, loopStart: head, shortened: false };
    }
    const b = SLOT_SAMPLES, a = b - start >= SLOT_SAMPLES / 4 ? start : b / 2;
    const x = Math.min(4096, Math.floor((b - a) / 2), a);
    const out = Int16Array.from(pcm.subarray(0, b));
    for (let i = 0; i < x; i++) {
      const t = (i + 1) / (x + 1);
      out[b - x + i] = Math.trunc(pcm[b - x + i] * (1 - t) + pcm[a - x + i] * t);
    }
    return { pcm: out, loopStart: a, shortened: true };
  }

  // {rate, start, end (exclusive)} from a WAV's first 'smpl' loop, or null. Port of wav_loop().
  function wavLoop(bytes) {
    if (ascii(bytes, 0, 4) !== "RIFF" || ascii(bytes, 8, 4) !== "WAVE") return null;
    let rate = 0, loop = null, i = 12;
    while (i + 8 <= bytes.length) {
      const id = ascii(bytes, i, 4), size = u32(bytes, i + 4), body = i + 8;
      if (id === "fmt ") rate = u32(bytes, body + 4);
      else if (id === "smpl" && size >= 60 && u32(bytes, body + 28) > 0)
        loop = [u32(bytes, body + 44), u32(bytes, body + 48) + 1];     // smpl loop end is inclusive
      i = body + size + (size & 1);
    }
    return rate && loop && loop[1] > loop[0] ? { rate, start: loop[0], end: loop[1] } : null;
  }

  // The .pcm file: 4-byte header {format, loop flag, u16 loop start}, then the data.
  function encodeSample(pcm, eightBit, loopStart) {
    pcm = pcm.subarray(0, SLOT_SAMPLES);
    const step = eightBit ? 4 : 2;
    if (loopStart !== null && loopStart !== undefined) {
      const trim = pcm.length % step;
      if (loopStart >= trim) { pcm = pcm.subarray(trim); loopStart -= trim; }
      else if (pcm.length - trim - loopStart >= 2) pcm = pcm.subarray(0, pcm.length - trim);
      else loopStart = null;
    } else loopStart = null;
    const bytes = eightBit ? pcm.length : pcm.length * 2;
    const out = new Uint8Array(4 + alignUp(bytes, 4));
    out[0] = eightBit ? 1 : 0;
    out[1] = loopStart !== null ? 1 : 0;
    put16(out, 2, loopStart !== null ? loopStart : 0);
    if (eightBit) for (let i = 0; i < pcm.length; i++) out[4 + i] = Math.max(-128, Math.min(127, (pcm[i] + 128) >> 8)) & 255;
    else for (let i = 0; i < pcm.length; i++) put16(out, 4 + i * 2, pcm[i] & 0xFFFF);
    return out;
  }

  function setInitKit(dat) {                      // drum n plays sample 1, 33, 65, 97
    const d = Uint8Array.from(dat);
    const sum = md5(d.subarray(0x10));            // unknown layout? leave the file alone
    if (d.length < INIT_DRUM_PATCHES + 4 * 31 || !sum.every((x, i) => x === d[i])) return dat;
    for (let n = 0; n < 4; n++) {
      const p = INIT_DRUM_PATCHES + 31 * n;
      d[p + 6] = n; d[p + 7] = 0; d[p + 8] = 0xC1; d[p + 9] = 0; d[p + 10] = 0;
    }
    d.set(md5(d.subarray(0x10)), 0);
    return d;
  }

  // ---------- rebuild ----------
  // samples: {number (1-128): Uint8Array .pcm file}. Returns the patched ROM as a Uint8Array.
  function buildRom(p, v, samples) {
    const { arm9, footer } = patchArm9(p, v);
    const dirs = p.dirs.map(d => ({ first: d.first, parent: d.parent, entries: d.entries.slice() }));
    const files = p.files.slice();
    const initId = findFile(p, "data/demo/ds10init.dat");
    if (initId >= 0) files[initId] = setInitKit(p.files[initId]);
    // new directory /data/smp with the samples; its file ids come after all existing ones
    const dataDir = dirs[0].entries.find(e => e.dir && e.name === "data");
    if (!dataDir) throw new Error("no /data folder");
    const nums = Object.keys(samples).map(Number).sort((a, b) => a - b);
    const smpId = 0xF000 + dirs.length;
    dirs.push({ first: files.length, parent: dataDir.id, entries: nums.map(n => ({ dir: false, name: String(n).padStart(3, "0") + ".pcm" })) });
    dirs[dataDir.id & 0x0FFF].entries.push({ dir: true, name: "smp", id: smpId });
    nums.forEach(n => files.push(samples[n]));
    const fnt = buildFnt(dirs);

    // layout: header | arm9 (+footer) | arm9 ovt | arm7 | arm7 ovt | FNT | FAT | banner | files
    let pos = p.headerSize || 0x4000;
    const place = (len) => { const at = alignUp(pos); pos = at + len; return at; };
    const arm9Off = place(arm9.length + footer.length);
    const ovt9Off = p.arm9Ovt.length ? place(p.arm9Ovt.length) : 0;
    const arm7Off = place(p.arm7.length);
    const ovt7Off = p.arm7Ovt.length ? place(p.arm7Ovt.length) : 0;
    const fntOff = place(fnt.length);
    const fatOff = place(files.length * 8);
    const bannerOff = p.banner.length ? place(p.banner.length) : 0;
    const order = files.map((_, i) => i).sort((a, b) =>      // existing files keep their ROM order
      (a < p.files.length ? p.files[a].byteOffset : Infinity) - (b < p.files.length ? p.files[b].byteOffset : Infinity) || a - b);
    const fileOff = new Array(files.length);
    for (const i of order) fileOff[i] = place(files[i].length);
    const total = pos;

    const rom = new Uint8Array(total);
    rom.set(p.rom.subarray(0, p.headerSize || 0x4000));
    rom.set(arm9, arm9Off); rom.set(footer, arm9Off + arm9.length);
    if (ovt9Off) rom.set(p.arm9Ovt, ovt9Off);
    rom.set(p.arm7, arm7Off);
    if (ovt7Off) rom.set(p.arm7Ovt, ovt7Off);
    rom.set(fnt, fntOff);
    files.forEach((f, i) => { put32(rom, fatOff + i * 8, fileOff[i]); put32(rom, fatOff + i * 8 + 4, fileOff[i] + f.length); rom.set(f, fileOff[i]); });
    if (bannerOff) rom.set(p.banner, bannerOff);

    put32(rom, 0x20, arm9Off); put32(rom, 0x2C, arm9.length);
    put32(rom, 0x50, ovt9Off); put32(rom, 0x54, p.arm9Ovt.length);
    put32(rom, 0x30, arm7Off); put32(rom, 0x3C, p.arm7.length);
    put32(rom, 0x58, ovt7Off); put32(rom, 0x5C, p.arm7Ovt.length);
    put32(rom, 0x40, fntOff); put32(rom, 0x44, fnt.length);
    put32(rom, 0x48, fatOff); put32(rom, 0x4C, files.length * 8);
    put32(rom, 0x68, bannerOff);
    put32(rom, 0x80, total);
    let cap = 0;
    while ((0x20000 << cap) < total) cap++;
    rom[0x14] = cap;
    put16(rom, 0x15E, crc16(rom.subarray(0, 0x15E)));
    return rom;
  }

  return { parseRom, identify, buildRom, encodeSample, fitLoop, setInitKit, findFile, wavLoop, crc32, crc16, md5,
           SLOT_SAMPLES, controls: n => { const i = n - 1; return { vco1: i >> 5, vco2: i >> 3 & 3, sync: i >> 2 & 1, pitch: i >> 1 & 1, bal: i & 1 }; } };
})();
if (typeof module !== "undefined") module.exports = DS10;
