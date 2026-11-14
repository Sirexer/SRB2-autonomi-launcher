// Renders flag-icons (MIT, npm "flag-icons") 4x3 SVGs to 32x24 PNGs in
// assets/flags/ for the Servers tab: node tools/render_flags.js <flags/4x3> assets/flags
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
(async () => {
  const src = process.argv[2], out = process.argv[3];
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 32, height: 24 }, deviceScaleFactor: 1 });
  const files = fs.readdirSync(src).filter(f => /^[a-z]{2}\.svg$/.test(f));
  for (const f of files) {
    const svg = fs.readFileSync(path.join(src, f), 'utf8');
    await page.setContent(`<html><body style="margin:0;background:transparent"><img style="display:block;width:32px;height:24px" src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}"></body></html>`);
    await page.waitForFunction(() => document.querySelector('img').complete);
    await page.screenshot({ path: path.join(out, f.replace('.svg', '.png')), omitBackground: true });
  }
  await browser.close();
  console.log(files.length);
})();
