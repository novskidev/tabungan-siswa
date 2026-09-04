// Render maskable.svg → PNG ikon PWA (jalankan ulang jika ikon SVG berubah).
import { readFileSync, writeFileSync } from 'node:fs';
import { Resvg } from '@resvg/resvg-js';

const svg = readFileSync('public/maskable.svg', 'utf8');
for (const size of [180, 192, 512]) {
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: size } })
    .render()
    .asPng();
  const name = size === 180 ? 'apple-touch-icon.png' : `icon-${size}.png`;
  writeFileSync(`public/${name}`, png);
  console.log(`public/${name}`);
}
