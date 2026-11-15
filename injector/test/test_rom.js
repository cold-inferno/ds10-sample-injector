// Node test: build the EU ROM with the V1.1 samples via core.js and compare with the tested V1.1 ROM.
const fs = require("fs"), path = require("path");
const DS10 = require("../src/core.js");
const root = path.join(__dirname, "..", "..");
const patches = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "patches.json")));
const load = f => new Uint8Array(fs.readFileSync(f));
const eq = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

const src = DS10.parseRom(load(path.join(root, "ROMZ", "Korg DS-10 Synthesizer (Europe) (En,Fr,De,Es,It).nds")));
const id = DS10.identify(src, patches);
console.log("identify:", id.ok ? "ok " + src.code : id.reason);
const smpDir = path.join(root, "rom-patch", "build", "data", "data", "smp");
const samples = {};
for (const f of fs.readdirSync(smpDir)) samples[parseInt(f, 10)] = load(path.join(smpDir, f));
const out = DS10.buildRom(src, id.version, samples);
fs.writeFileSync(path.join(__dirname, "out-eu.nds"), out);

const built = DS10.parseRom(out);
const ref = DS10.parseRom(load(process.env.REF_ROM || path.join(root, "milestones", "V1.1 M01 library", "korg-ds10-samples-v1.1.nds")));
console.log("arm9 == reference ROM:", eq(built.arm9, ref.arm9), "| footer:", eq(built.arm9Footer, ref.arm9Footer), "| arm7:", eq(built.arm7, ref.arm7), "| banner:", eq(built.banner, ref.banner));
// every file, by path
function walk(p, dir = 0, prefix = "", acc = {}) {
  const d = p.dirs[dir]; let idx = 0;
  for (const e of d.entries) {
    if (e.dir) walk(p, e.id & 0xFFF, prefix + e.name + "/", acc);
    else acc[prefix + e.name] = p.files[d.first + idx++];
  }
  return acc;
}
const a = walk(built), b = walk(ref);
const names = new Set([...Object.keys(a), ...Object.keys(b)]);
let same = 0, diff = [];
for (const n of names) (a[n] && b[n] && eq(a[n], b[n])) ? same++ : diff.push(n);
console.log(`files: ${same}/${names.size} identical`, diff.length ? "differ: " + diff.slice(0, 5).join(", ") : "");
// file ids of the original files must not move
const orig = walk(src); let moved = 0;
for (const n in orig) if (DS10.findFile(src, n) !== DS10.findFile(built, n)) moved++;
console.log("original files with a changed id:", moved);
const h = (r, o) => Buffer.from(r.subarray(o, o + 8)).toString("hex");
console.log("header 0x60 (ROM control) kept:", h(out, 0x60) === h(src.rom, 0x60), "| secure CRC kept:", h(out, 0x6C).slice(0, 4) === h(src.rom, 0x6C).slice(0, 4),
            "| header CRC ok:", DS10.crc16(out.subarray(0, 0x15E)) === (out[0x15E] | out[0x15F] << 8), "| size", out.length, "cap", out[0x14]);
