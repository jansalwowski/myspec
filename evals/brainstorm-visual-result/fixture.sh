#!/usr/bin/env bash
# A spike already rendered two comparison images; the brainstorm has to show them, not link them.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../_fixtures/lib.sh"
myspec_init
mkdir -p spike/out
# Two small real PNGs (grey frame, a lighter "plate" band), written without image tooling.
node -e '
const fs = require("fs"), zlib = require("zlib");
const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcTable[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => { const t = Buffer.from(type), len = Buffer.alloc(4), sum = Buffer.alloc(4); len.writeUInt32BE(data.length); sum.writeUInt32BE(crc(Buffer.concat([t, data]))); return Buffer.concat([len, t, data, sum]); };
function png(file, plate) {
  const w = 160, h = 90, rows = [];
  for (let y = 0; y < h; y++) { const row = [0]; for (let x = 0; x < w; x++) { const inPlate = x > 50 && x < 110 && y > 55 && y < 72; const v = inPlate ? plate : 90 + ((x + y) % 20); row.push(v, v, v); } rows.push(Buffer.from(row)); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  fs.writeFileSync(file, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(Buffer.concat(rows))), chunk("IEND", Buffer.alloc(0))]));
}
png("spike/out/compare-synthetic.png", 200);
png("spike/out/compare-crops.png", 140);
'
cat > spike/NOTES.md <<'NOTES'
# Plate anonymisation spike

Five street frames, two treatments: synthetic gaussian blur over the detected plate, and a real plate crop from a licensed set pasted over it.

- spike/out/compare-synthetic.png
- spike/out/compare-crops.png
NOTES
git_commit_all "chore: plate anonymisation spike output"
