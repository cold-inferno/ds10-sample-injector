const fs = require("fs"), DS10 = require("../src/core.js");
const sp = process.argv[2], meta = JSON.parse(fs.readFileSync(sp + "/meta.json"));
let ok = 0, bad = [];
for (const n in meta) {
  const m = meta[n], f = String(n).padStart(3, "0");
  const buf = fs.readFileSync(`${sp}/${f}.raw`), pcm = new Int16Array(buf.buffer, buf.byteOffset, buf.length / 2);
  let data;
  if (m.ls !== null) { const r = DS10.fitLoop(pcm, m.ls, m.le); data = DS10.encodeSample(r.pcm, m.eight, r.loopStart); }
  else data = DS10.encodeSample(pcm, m.eight, null);
  const want = new Uint8Array(fs.readFileSync(`${sp}/${f}.py.pcm`));
  (data.length === want.length && data.every((x, i) => x === want[i])) ? ok++ : bad.push(f);
}
console.log(`encode: ${ok}/${Object.keys(meta).length} identical to build_lib.py`, bad.length ? "differ: " + bad.join(",") : "");
