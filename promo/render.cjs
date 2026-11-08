// Render promo/index.html frame by frame to frames/*.png.
// Usage: node render.cjs [--out frames] [--start 0] [--end N] [--fps 30]
const { chromium } = require('playwright-core');
const path = require('path');
const fs = require('fs');

const ROOT = __dirname;

function arg(name, def) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 ? process.argv[i + 1] : def;
}

const OUT = path.resolve(ROOT, arg('out', 'frames'));
const FPS = Number(arg('fps', 30));
const START = Number(arg('start', 0));
const END = arg('end', null) === null ? null : Number(arg('end'));
const AT = arg('at', null);
const VIEW = { width: 1920, height: 1080 };

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const page = await browser.newPage({ viewport: VIEW, deviceScaleFactor: 1 });
  await page.goto('file://' + path.join(ROOT, 'index.html'));
  await page.waitForFunction('window.__Grabi !== undefined');
  await page.evaluate(() => document.fonts.ready);

  const meta = await page.evaluate(() => ({ FPS: window.__Grabi.FPS, DUR: window.__Grabi.DUR }));
  const total = Math.round(meta.DUR * meta.FPS);
  const last = END === null ? total - 1 : END;

  if (AT !== null) {
    const times = AT.split(',').map(Number);
    const t0 = Date.now();
    for (const seconds of times) {
      const i = Math.round(seconds * meta.FPS);
      await page.evaluate((idx) => window.__Grabi.frame(idx), i);
      await page.screenshot({ path: path.join(OUT, 'at-' + String(i).padStart(5, '0') + '.png'), animations: 'disabled' });
    }
    await browser.close();
    console.log('\nprobe ' + times.length + ' frames in ' + (Date.now() - t0) + 'ms -> ' + OUT);
    return;
  }

  const t0 = Date.now();
  for (let i = START; i <= last; i++) {
    await page.evaluate((idx) => window.__Grabi.frame(idx), i);
    await page.screenshot({
      path: path.join(OUT, String(i).padStart(5, '0') + '.png'),
      animations: 'disabled',
    });
    if ((i - START) % 60 === 0) {
      const done = i - START + 1, need = last - START + 1;
      const rate = done / ((Date.now() - t0) / 1000);
      process.stdout.write(`\rframe ${i}/${last}  ${(rate).toFixed(1)} fps  eta ${(((need - done) / rate) | 0)}s   `);
    }
  }
  await browser.close();
  console.log(`\ndone: ${START}..${last} (${last - START + 1} frames) -> ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });
