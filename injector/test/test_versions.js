const fs = require("fs"), path = require("path"), DS10 = require("../src/core.js");
const root = path.join(__dirname, "..", ".."), patches = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "patches.json")));
const smpDir = path.join(root, "rom-patch", "build", "data", "data", "smp"), samples = {};
for (const f of fs.readdirSync(smpDir)) samples[parseInt(f, 10)] = new Uint8Array(fs.readFileSync(path.join(smpDir, f)));
for (const f of fs.readdirSync(path.join(root, "ROMZ")).filter(f => f.endsWith(".nds"))) {
  const p = DS10.parseRom(new Uint8Array(fs.readFileSync(path.join(root, "ROMZ", f))));
  const id = DS10.identify(p, patches);
  if (!id.ok) { console.log(`${p.code} ${f.slice(0, 50)}: ${id.reason}`); continue; }
  const out = DS10.buildRom(p, id.version, samples), q = DS10.parseRom(out);
  const smp = DS10.findFile(q, "data/smp/001.pcm"), init = DS10.findFile(q, "data/demo/ds10init.dat");
  fs.writeFileSync(path.join(__dirname, `out-${p.code}.nds`), out);
  console.log(`${p.code} ${f.slice(0, 50)}: built ${out.length} bytes, smp/001 id ${smp}, init id ${init} (orig ${DS10.findFile(p, "data/demo/ds10init.dat")})`);
}
