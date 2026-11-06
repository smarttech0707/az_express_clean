'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const lot = require('../../scripts/restaurant-v2-pilot/lot');
const selfie = require('../../scripts/restaurant-v2-pilot/selfie');
const firstRun = require('../../scripts/restaurant-v2-pilot/firstRun');
const { storageObjectOfUrl } = require('../proofStorage');
const { PARTNER_ACTIONS } = require('../partnerOrderActions');

const ORDER = 'order-xyz';

test('selfie : JPEG synthétique valide, moins de 5 Mo', () => {
  const b = selfie.selfieBytes();
  assert.deepEqual([...b.subarray(0, 3)], [0xff, 0xd8, 0xff]);
  assert.deepEqual([...b.subarray(-2)], [0xff, 0xd9]);
  assert.ok(b.length > 0 && b.length < selfie.MAX_BYTES);
  assert.equal(b.includes(Buffer.from('Exif')), false);
});

test('selfie : chemin attendu et règles Storage reproduites', () => {
  assert.equal(selfie.selfiePath(ORDER), `acceptance_selfies/${ORDER}/t7e-driver.jpg`);
  const ok = { objectPath: selfie.selfiePath(ORDER), contentType: 'image/jpeg', size: 2000, uid: 't7e-driver' };
  assert.deepEqual(selfie.validateUpload(ok), []);
  assert.ok(selfie.validateUpload({ ...ok, uid: 't7e-client' }).length);
  assert.ok(selfie.validateUpload({ ...ok, contentType: 'text/plain' }).length);
  assert.ok(selfie.validateUpload({ ...ok, size: selfie.MAX_BYTES }).length);
  assert.ok(selfie.validateUpload({ ...ok, signInProvider: 'anonymous' }).length);
  assert.ok(selfie.validateUpload({ ...ok, objectPath: 'autre/chemin.jpg' }).length);
});

test('selfie : l’URL de téléchargement est reconnue par proofStorage', () => {
  const url = selfie.downloadUrl(selfie.selfiePath(ORDER), 'tok-1');
  assert.equal(storageObjectOfUrl(url, lot.TARGET.storageBucket), selfie.selfiePath(ORDER));
  assert.equal(storageObjectOfUrl(url, 'autre-bucket'), null);
});

test('selfie : la requête de dépôt ne contient aucun jeton', () => {
  const up = selfie.buildSelfieUpload(ORDER);
  assert.equal(up.method, 'POST');
  assert.match(up.url, /acceptance_selfies%2Forder-xyz%2Ft7e-driver\.jpg/);
  assert.doesNotMatch(up.headers.Authorization, /eyJ/);
});

test('catalogue : chaque étape appelle une fonction connue et documente ses critères', () => {
  const names = new Set(Object.values(firstRun.FN));
  for (const s of firstRun.STEPS) {
    if (s.fn) assert.ok(names.has(s.fn), s.id);
    assert.ok(s.pass.length && s.fail.length && s.effects.length && s.preconditions.length, s.id);
    assert.equal(typeof s.money({ totalAmount: 1, productAmount: 1, deliveryFee: 1, commission: 1 }), 'string');
  }
  for (const fn of Object.values(firstRun.FN).filter((f) => f !== firstRun.FN.dispatch)) assert.ok(firstRun.stepsByFunction(fn).length, fn);
  assert.equal(firstRun.stepsByFunction(firstRun.FN.dispatch).length, 0);
});

test('catalogue : actions de partnerOrderActionCF reconnues par la fonction réelle', () => {
  for (const s of firstRun.stepsByFunction(firstRun.FN.partner)) {
    const d = s.data({ orderId: ORDER });
    assert.ok(d.action === 'setPartnerOrdersConfig' || PARTNER_ACTIONS.includes(d.action), s.id);
  }
});

test('catalogue : les appelants respectent les rôles du parcours', () => {
  const who = Object.fromEntries(firstRun.STEPS.map((s) => [s.id, s.caller]));
  assert.deepEqual([who.S0, who.S1, who.S2, who.S3, who.S7, who.S8, who.S9, who.S10, who.S11],
    ['admin', 'client', 'client', 'restaurant', 'driver', 'restaurant', 'driver', 'client', 'driver']);
});

test('catalogue : paramètres de devis, création et preuves', () => {
  const byId = Object.fromEntries(firstRun.STEPS.map((s) => [s.id, s]));
  const ctx = { orderId: ORDER, quoteId: 'q1', total: 7000, selfieUrl: 'u', pickup: { pin: '123456' }, delivery: { token: 'tk' } };
  const quote = byId.S1.data(ctx);
  assert.deepEqual(Object.keys(quote).sort(), ['destination', 'items', 'sellerId', 'sellerType']);
  assert.equal(quote.sellerId, 't7e-resto');
  const create = byId.S2.data(ctx);
  assert.equal(create.paymentMethod, 'wallet');
  assert.equal(create.confirmedAmount, 7000);
  assert.deepEqual(byId.S8.data(ctx), { orderId: ORDER, type: 'pickup' });
  assert.deepEqual(byId.S10.data(ctx), { orderId: ORDER, type: 'delivery' });
  assert.deepEqual(byId.S9.data(ctx), { orderId: ORDER, pin: '123456' });
  assert.deepEqual(byId.S11.data(ctx), { orderId: ORDER, proofToken: 'tk' });
  assert.deepEqual(byId.S7.data(ctx), { orderId: ORDER, acceptanceSelfieUrl: 'u' });
});

test('catalogue : callableRequest refuse l’absence de jeton et ne l’écrit pas ailleurs', () => {
  assert.throws(() => firstRun.callableRequest('https://x', 'abc', {}));
  const jwt = 'a.b.c';
  const r = firstRun.callableRequest('https://x', jwt, { k: 1 });
  assert.equal(r.init.headers.Authorization, `Bearer ${jwt}`);
  assert.equal(r.init.body, '{"data":{"k":1}}');
  assert.deepEqual(firstRun.parseCallableResponse(200, { result: { success: true } }), { ok: true, result: { success: true } });
  assert.equal(firstRun.parseCallableResponse(400, { error: { status: 'INVALID_ARGUMENT', message: 'm' } }).ok, false);
});

test('catalogue : aucun secret ni jeton dans les définitions', () => {
  const dump = JSON.stringify(firstRun.STEPS.map((s) => ({ ...s, data: undefined, money: undefined })));
  assert.doesNotMatch(dump, /eyJ|AIza|password/i);
});

// ── Adaptateur cloud de l'exécuteur : tout est simulé (aucun réseau) ────────────────────────────────────────────────────────
const runner = require('../../scripts/restaurant-v2-pilot/runStep');
const jwt = (claims) => `h.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.s`;
const target = { mode: 'preprod', projectId: 'az-express-preprod' };
const manifest = { lot: 't7e-lot-1', status: 'complete', project: { id: 'az-express-preprod', number: '306761725053' }, baseline: { orderIds: ['h1'] } };
const credentials = { client: { email: 't7e-client@example.invalid', password: 'x' }, driver: { email: 't7e-driver@example.invalid', password: 'x' } };
const fakeAdmin = { firestore: () => ({ doc: () => ({ get: async () => ({ exists: false }) }) }), credential: { applicationDefault: () => ({ getAccessToken: async () => ({ access_token: 'adc' }) }) } };
const json = (status, body) => ({ ok: status < 300, status, json: async () => body });

test('cloudIo : refus hors préproduction, sans clé, avec un manifeste d’un autre projet', () => {
  const ok = { admin: fakeAdmin, target, credentials, manifest, apiKey: 'k' };
  assert.doesNotThrow(() => runner.cloudIo(ok));
  assert.throws(() => runner.cloudIo({ ...ok, target: { mode: 'emulator', projectId: 'demo-x' } }), (e) => e.code === 'PREPROD_ONLY');
  assert.throws(() => runner.cloudIo({ ...ok, apiKey: '' }), (e) => e.code === 'API_KEY_REQUIRED');
  assert.throws(() => runner.cloudIo({ ...ok, manifest: { ...manifest, project: { id: 'az-express-b0469', number: '1' } } }), (e) => e.code === 'MANIFEST_MISMATCH');
});

test('cloudIo : connexion vérifiée (projet, uid), appel sur l’URI de la fonction avec le jeton du compte', async () => {
  const calls = [];
  const good = jwt({ aud: 'az-express-preprod', sub: 't7e-client' });
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    if (url.includes('identitytoolkit')) return json(200, { idToken: good });
    if (url.includes('cloudfunctions.googleapis.com')) return json(200, { serviceConfig: { uri: 'https://quotepartnerordercf-abc-ew.a.run.app' } });
    return json(200, { result: { success: true } });
  };
  const io = runner.cloudIo({ admin: fakeAdmin, target, credentials, manifest, apiKey: 'k', fetchImpl });
  assert.deepEqual(await io.identity('client'), { uid: 't7e-client' });
  assert.deepEqual(await io.call('quotePartnerOrderCF', 'client', { a: 1 }), { success: true });
  const last = calls.at(-1);
  assert.equal(last.url, 'https://quotepartnerordercf-abc-ew.a.run.app');
  assert.equal(last.init.headers.Authorization, `Bearer ${good}`);
  assert.ok(calls.some((c) => c.url.includes('/projects/az-express-preprod/locations/europe-west1/')), 'projet préproduction uniquement');
  assert.ok(!calls.some((c) => /b0469|az-express-clean/.test(c.url)));

  const wrongProject = runner.cloudIo({ admin: fakeAdmin, target, credentials, manifest, apiKey: 'k', fetchImpl: async () => json(200, { idToken: jwt({ aud: 'az-express-b0469', sub: 't7e-client' }) }) });
  await assert.rejects(wrongProject.identity('client'), (e) => e.code === 'WRONG_IDENTITY');
  const wrongUid = runner.cloudIo({ admin: fakeAdmin, target, credentials, manifest, apiKey: 'k', fetchImpl: async () => json(200, { idToken: jwt({ aud: 'az-express-preprod', sub: 'real-client' }) }) });
  await assert.rejects(wrongUid.identity('client'), (e) => e.code === 'WRONG_IDENTITY');
  const badUri = runner.cloudIo({ admin: fakeAdmin, target, credentials, manifest, apiKey: 'k', fetchImpl: async (url) => (url.includes('identitytoolkit') ? json(200, { idToken: good }) : json(200, { serviceConfig: { uri: 'https://evil.example.com' } })) });
  await assert.rejects(badUri.call('quotePartnerOrderCF', 'client', {}), (e) => e.code === 'BAD_FUNCTION_URI');
  const noCred = runner.cloudIo({ admin: fakeAdmin, target, credentials, manifest, apiKey: 'k', fetchImpl });
  await assert.rejects(noCred.identity('admin'), (e) => e.code === 'WRONG_IDENTITY');
});

test('cloudIo : dépôt du selfie par le livreur uniquement, URL de téléchargement conforme', async () => {
  const good = jwt({ aud: 'az-express-preprod', sub: 't7e-driver' });
  let upload;
  const fetchImpl = async (url, init) => {
    if (url.includes('identitytoolkit')) return json(200, { idToken: good });
    upload = { url, init };
    return json(200, { downloadTokens: 'tok-1' });
  };
  const io = runner.cloudIo({ admin: fakeAdmin, target, credentials, manifest, apiKey: 'k', fetchImpl });
  const up = selfie.buildSelfieUpload('ord-1');
  const url = await io.uploadSelfie(up);
  assert.equal(upload.init.headers.Authorization, `Firebase ${good}`);
  assert.equal(upload.init.headers['Content-Type'], 'image/jpeg');
  assert.equal(storageObjectOfUrl(url, lot.TARGET.storageBucket), 'acceptance_selfies/ord-1/t7e-driver.jpg');
});
