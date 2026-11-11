// Builds the asset sources in assets/ from the Ratify badge, then
// `npm run assets` hands them to capacitor-assets. Re-run it whenever the
// client sends new artwork.
//
// Source: assets-source/ratify-black-base44.png is the icon the site itself
// uses (favicon / apple-touch-icon in index.html, from media.base44.com),
// 1024px with transparent corners around a round black-and-red badge.
//
// App Store icons must be opaque, so the badge is flattened onto the site's
// #080808, which is also the launch screen and WebView colour.
import sharp from 'sharp';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdirSync } from 'node:fs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const source = path.join(root, 'assets-source', 'ratify-black-base44.png');
const out = path.join(root, 'assets');
const SURFACE = { r: 8, g: 8, b: 8, alpha: 1 };
mkdirSync(out, { recursive: true });

// Icon: the badge already sits inside its canvas with a margin, so keep it at
// full size and only drop the alpha channel.
await sharp(source)
  .resize(1024, 1024)
  .flatten({ background: SURFACE })
  .removeAlpha()
  .png()
  .toFile(path.join(out, 'icon-only.png'));

// Launch screen: the badge at 1100px in the middle of a 2732px square, the
// size capacitor-assets expects. ShellViewController places its spinner
// just below it (bottom edge at 50% + 20% of the height).
const badge = await sharp(source).resize(1100, 1100).png().toBuffer();
for (const name of ['splash.png', 'splash-dark.png']) {
  await sharp({ create: { width: 2732, height: 2732, channels: 4, background: SURFACE } })
    .composite([{ input: badge, gravity: 'center' }])
    .flatten({ background: SURFACE })
    .removeAlpha()
    .png()
    .toFile(path.join(out, name));
}
console.log('assets/: icon-only.png, splash.png, splash-dark.png');
