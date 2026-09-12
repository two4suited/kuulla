// Composites the App Store caption bands over the raw simulator captures.
//   cd <any dir> && npm i sharp
//   node <path-to-repo>/docs/brand/appstore/compose-screenshots.mjs
// Reads docs/brand/appstore/screenshots/raw/*.png, writes screenshots/6.9/*.png.
import { readFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { createRequire } from "node:module";

// Resolve `sharp` from the *current working directory* so the script can live in the
// repo while sharp is installed in a throwaway dir.
const sharp = createRequire(resolve(process.cwd(), "noop.js"))("sharp");

const AS = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(AS, "../../..");
const RAW = `${AS}/screenshots/raw`;
const OUT = `${AS}/screenshots/6.9`;
mkdirSync(OUT, { recursive: true });

const W = 1320, H = 2868, BAND = 560;
const sg = readFileSync(`${REPO}/ios/Kuulla/Kuulla/Fonts/SpaceGrotesk.ttf`).toString("base64");

// caption: [file, line1 parts...] where a part {t, k:true} is the lime keyword
const FRAMES = [
  { raw: "01-library.png", out: "01-library.png",
    lines: [[{ t: "Your shows, " }, { t: "synced", k: true }], [{ t: "to the second" }]] },
  { raw: "05-episodedetail.png", out: "02-episodedetail.png",
    lines: [[{ t: "Pause here.", k: true }], [{ t: "Resume there." }]] },
  { raw: "06-showdetail.png", out: "03-showdetail.png",
    lines: [[{ t: "Every episode, " }], [{ t: "filtered", k: true }, { t: " your way" }]] },
  { raw: "04-subscriptions.png", out: "04-subscriptions.png",
    lines: [[{ t: "Follow shows." }], [{ t: "Keep", k: true }, { t: " your place." }]] },
];

function tspans(parts) {
  return parts.map(p =>
    `<tspan fill="${p.k ? "#c6f24e" : "#f4f4f2"}">${p.t.replace(/&/g, "&amp;")}</tspan>`
  ).join("");
}

function bandSvg(lines) {
  const rows = lines.map((parts, i) =>
    `<text x="96" y="${232 + i * 132}" xml:space="preserve" font-family="SpaceGrotesk" font-weight="700"
       font-size="108" letter-spacing="-2">${tspans(parts)}</text>`
  ).join("\n");
  return Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${BAND}">
      <style>@font-face{font-family:"SpaceGrotesk";src:url(data:font/ttf;base64,${sg});}</style>
      <rect width="${W}" height="${BAND}" fill="#050505"/>
      ${rows}
      <rect x="98" y="${232 + lines.length * 132 - 4}" width="132" height="10" rx="5" fill="#c6f24e"/>
    </svg>`
  );
}

for (const f of FRAMES) {
  const src = sharp(`${RAW}/${f.raw}`);
  const meta = await src.metadata();
  if (meta.width !== W || meta.height !== H) {
    throw new Error(
      `${f.raw} is ${meta.width}x${meta.height}, expected ${W}x${H} — ` +
        `capture on a 6.9" device (iPhone 17 Pro Max). Not resizing.`
    );
  }
  const shot = await src.toBuffer();
  await sharp({ create: { width: W, height: H, channels: 3, background: "#050505" } })
    .composite([
      { input: shot, top: 0, left: 0 },
      { input: bandSvg(f.lines), top: 0, left: 0 },
    ])
    .png({ compressionLevel: 9 })
    .toFile(`${OUT}/${f.out}`);
  console.log("wrote", f.out);
}
console.log("done");
