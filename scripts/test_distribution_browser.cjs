// Requires playwright-core, pngjs and jsqr in NODE_PATH; Hosting local on port 5008.
// All browser requests to the production origin are intercepted and served locally.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright-core');
const { PNG } = require('pngjs');
const jsQR = require('jsqr');
const root = path.resolve(__dirname, '..');
const origin = 'https://az-express-b0469.web.app';
const expected = origin + '/telecharger';
function decode(buffer, label) {
  const png = PNG.sync.read(buffer);
  const code = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
  assert.equal(code?.data, expected, label);
  console.log('PASS QR:', label, code.data);
}
(async () => {
  for (const name of ['az-express-qr.png', 'az-express-qr-logo.png', 'az-express-affiche-a4.png']) {
    decode(fs.readFileSync(path.join(root, 'build/web/distribution/qr', name)), name);
  }
  const browser = await chromium.launch({channel: 'msedge', headless: true});
  let cases = 0;
  try {
    const qrPage = await browser.newPage({viewport: {width: 1200, height: 1600}});
    for (const name of ['az-express-qr.svg', 'az-express-qr-logo.svg', 'az-express-affiche-a4.svg']) {
      const svg = fs.readFileSync(path.join(root, 'build/web/distribution/qr', name), 'utf8');
      await qrPage.setContent('<style>body{margin:0}svg{width:1000px;height:auto}</style>' + svg);
      decode(await qrPage.locator('svg').first().screenshot(), name);
    }
    await qrPage.close();
    for (const mode of ['desktop', 'mobile', 'unpublished', 'bad-size', 'bad-mime', 'missing-apk', 'bad-origin', 'manifest-error']) {
      const context = await browser.newContext({viewport: mode === 'mobile' ? {width: 375, height: 812} : {width: 1280, height: 900}});
      await context.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.origin !== origin) return route.abort();
        if (url.pathname === '/distribution/latest.json' && mode === 'manifest-error') return route.fulfill({status: 500, body: ''});
        if (url.pathname.endsWith('.apk') && mode === 'missing-apk') return route.fulfill({status: 404, body: ''});
        // Resolve Hosting's /telecharger -> /telecharger/ redirect locally so
        // the browser never follows a redirect outside this interception.
        const response = await fetch('http://127.0.0.1:5008' + url.pathname + url.search, {method: route.request().method(), redirect: 'follow'});
        const headers = Object.fromEntries(response.headers);
        delete headers['transfer-encoding'];
        delete headers['content-encoding'];
        if (headers.location) headers.location = headers.location.replace('http://127.0.0.1:5008', origin);
        let body = Buffer.from(await response.arrayBuffer());
        if (url.pathname === '/distribution/latest.json') {
          const release = JSON.parse(body.toString());
          if (mode === 'unpublished') release.published = false;
          if (mode === 'bad-origin') release.downloadUrl = 'https://example.invalid/test.apk';
          body = Buffer.from(JSON.stringify(release));
          headers['content-length'] = String(body.length);
        }
        if (url.pathname.endsWith('.apk')) {
          if (mode === 'bad-size') headers['content-length'] = '42';
          if (mode === 'bad-mime') headers['content-type'] = 'text/html';
        }
        await route.fulfill({status: response.status, headers, body});
      });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      await page.goto(expected);
      assert.equal(await page.locator('#button-label').count(), 1, `Page attendue absente : ${page.url()} ; ${(await page.content()).slice(0,200)}`);
      await page.waitForFunction(() => !document.getElementById('button-label').textContent.includes('Vérification'));
      const button = page.locator('#download-button');
      if (['desktop', 'mobile'].includes(mode)) {
        assert.equal(await button.getAttribute('aria-disabled'), null);
        assert.equal(await button.getAttribute('href'), origin + '/downloads/az-express-latest.apk');
        assert.match(await button.textContent(), /Télécharger pour Android/);
        assert.equal(await page.locator('#version').textContent(), '1.0.9');
        assert.ok(await page.locator('#checksum').isVisible());
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'Débordement horizontal');
        assert.ok((await page.locator('body').textContent()).includes('signature différente'));
        for (const href of ['/#/confidentialite', '/#/delete-account']) assert.equal(await page.locator(`a[href="${href}"]`).count(), 1);
      } else {
        assert.equal(await button.getAttribute('aria-disabled'), 'true');
        assert.equal(await button.getAttribute('href'), '#');
      }
      assert.deepEqual(errors, []);
      console.log('PASS page:', mode);
      cases++;
      await context.close();
    }
  } finally { await browser.close(); }
  console.log(`PASS: 6 QR décodés, ${cases} scénarios navigateur. Aucun accès au site de production.`);
})().catch(e => { console.error(e); process.exitCode = 1; });
