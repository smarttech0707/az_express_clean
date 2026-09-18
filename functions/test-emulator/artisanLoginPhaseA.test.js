'use strict';

const { createIsolatedFirestoreTest } = require('./support/isolatedFirestoreTest');
const assert = require('node:assert/strict');
const { randomInt } = require('node:crypto');
const { settleConcurrent } = require('./support/settleConcurrent');
const admin = require('firebase-admin');
const { buildArtisanLogin } = require('../artisanAccounts');
const { buildResetAccountPassword } = require('../passwordReset');
const { hashSecret, verifySecret } = require('../passwordHash');

const host = process.env.FIRESTORE_EMULATOR_HOST || '';
assert.match(host, /^(127\.0\.0\.1|localhost):\d+$/, 'Local emulator required');
const { test, db, fixture, ref } = createIsolatedFirestoreTest('demo-lot74');
const fieldValue = admin.firestore.FieldValue;
const phone = '0700000000';
const provider = ref('service_providers/provider');
const credential = ref('artisan_credentials/provider');

const request = (pin = fixture().oldPin) => ({ auth: { uid: 'artisan' }, data: { phone, pin } });
const login = (database = db, checkRateLimit = async () => {}) =>
  buildArtisanLogin({ db: database, checkRateLimit });

test.beforeEach(async () => {
  fixture().oldPin = String(randomInt(100000, 1000000));
  do { fixture().newPin = String(randomInt(100000, 1000000)); } while (fixture().newPin === fixture().oldPin);
  await provider.set({ phone, artisanPin: fixture().oldPin, status: 'approved', name: 'Fixture', photos: [] });
});

test('phase A: historical login and replay preserve public data without creating credentials', async () => {
  for (let i = 0; i < 2; i++) {
    const result = await login()(request());
    assert.equal(result.success, true);
    const data = (await provider.get()).data();
    assert.ok(data.artisanPin === fixture().oldPin, 'Historical credential must remain unchanged');
    assert.equal(data.artisanUid, 'artisan');
    assert.equal((await credential.get()).exists, false);
    assert.ok(!Object.hasOwn(result.data, 'artisanPin'));
  }
});

test('phase A: private credential authenticates without cleaning a matching public field', async () => {
  const before = { hash: hashSecret(fixture().oldPin) };
  await credential.set(before);
  assert.equal((await login()(request())).success, true);
  assert.ok((await provider.get()).data().artisanPin === fixture().oldPin);
  assert.ok((await credential.get()).data().hash === before.hash);
});

test('phase A: private-only accounts remain compatible', async () => {
  await provider.update({ artisanPin: fieldValue.delete() });
  await credential.set({ hash: hashSecret(fixture().newPin) });
  assert.equal((await login()(request(fixture().newPin))).success, true);
  assert.equal(Object.hasOwn((await provider.get()).data(), 'artisanPin'), false);
});

test('phase A: malformed private credential never falls back to the public field', async () => {
  await credential.set({ invalid: true });
  assert.equal((await login()(request())).success, false);
  assert.equal(Object.hasOwn((await provider.get()).data(), 'artisanUid'), false);
  assert.ok((await provider.get()).data().artisanPin === fixture().oldPin);
});

test('phase A: divergent private credential wins; no public fallback or cleanup', async () => {
  await credential.set({ hash: hashSecret(fixture().newPin) });
  assert.equal((await login()(request())).success, false);
  assert.equal((await login()(request(fixture().newPin))).success, true);
  assert.ok((await provider.get()).data().artisanPin === fixture().oldPin);
});

test('phase A: response exposes only the approved profile contract', async () => {
  await provider.update({ hash: 'fixture', password: 'fixture', fcmToken: 'fixture',
    idNumber: 'fixture', idPhotoUrl: 'fixture', credentials: { private: true } });
  const result = await login()(request());
  assert.deepEqual(Object.keys(result.data).sort(), ['artisanUid', 'name', 'phone', 'photos', 'status']);
});

test('phase A: authentication and rate limit failures precede account changes', async () => {
  let calls = 0;
  const run = login(db, async () => { calls++; throw new Error('Rate limited'); });
  await assert.rejects(run({ data: { phone, pin: fixture().oldPin } }), e => e.code === 'unauthenticated');
  assert.equal(calls, 0);
  await assert.rejects(run(request()), /Rate limited/);
  assert.equal(calls, 1);
  assert.equal(Object.hasOwn((await provider.get()).data(), 'artisanUid'), false);
  assert.equal((await credential.get()).exists, false);
});

test('phase A: incorrect historical credential cannot link an account', async () => {
  assert.equal((await login()(request(fixture().newPin))).success, false);
  assert.equal(Object.hasOwn((await provider.get()).data(), 'artisanUid'), false);
});

for (const privateBefore of [false, true]) {
  test(`phase A: login/reset race remains coherent (private=${privateBefore})`, { timeout: 30000 }, async () => {
    if (privateBefore) await credential.set({ hash: hashSecret(fixture().oldPin) });
    const reset = buildResetAccountPassword({ db, auth: {}, fieldValue, hashSecret, checkRateLimit: async () => {} });
    const resetRequest = { auth: { uid: 'verified-phone', token: { phone_number: '+2250700000000' } },
      data: { userType: 'artisan', phone, newValue: fixture().newPin } };
    const [result] = await settleConcurrent([login()(request()), reset(resetRequest)]);
    assert.equal(typeof result.success, 'boolean'); // Either serial order is legal.
    assert.ok(verifySecret(fixture().newPin, (await credential.get()).data().hash));
    assert.equal(Object.hasOwn((await provider.get()).data(), 'artisanPin'), false);
    assert.equal((await login()(request())).success, false);
    assert.equal((await login()(request(fixture().newPin))).success, true);
  });
}
