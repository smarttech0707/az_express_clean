'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { randomInt } = require('node:crypto');
const admin = require('firebase-admin');
const { setPin, migrateProvider } = require('../artisanCredentials');
const { buildArtisanLogin, buildSetArtisanPin } = require('../artisanAccounts');
const { buildResetAccountPassword } = require('../passwordReset');
const { hashSecret, verifySecret } = require('../passwordHash');
const { runMigration, migrationExitCode } = require('../scripts/migrateArtisanPins');

const host = process.env.FIRESTORE_EMULATOR_HOST || '';
assert.match(host, /^(127\.0\.0\.1|localhost):\d+$/, 'Local emulator required');
const projectId = 'demo-lot71';
const app = admin.initializeApp({ projectId }, `artisan-${process.pid}`);
const db = app.firestore();
const fieldValue = admin.firestore.FieldValue;
const phone = '0700000000';
const pin = () => String(randomInt(100000, 1000000));
let oldPin, newPin;
test.beforeEach(async () => {
  const response = await fetch(`http://${host}/emulator/v1/projects/${projectId}/databases/(default)/documents`, { method: 'DELETE' });
  assert.equal(response.status, 200);
  oldPin = pin();
  do { newPin = pin(); } while (newPin === oldPin);
});
test.after(() => app.delete());

async function seed({ status = 'pending', legacy = true, credential } = {}) {
  await db.doc('service_providers/provider').set({ phone, status, ...(legacy ? { artisanPin: oldPin } : {}) });
  if (credential) await db.doc('artisan_credentials/provider').set(credential);
}
async function state() {
  const [provider, credential] = await Promise.all([
    db.doc('service_providers/provider').get(), db.doc('artisan_credentials/provider').get(),
  ]);
  return { provider: provider.data(), credential: credential.data() };
}
const migrate = (database = db) => migrateProvider({ db: database, fieldValue, providerId: 'provider', dryRun: false });
const rotate = (value = newPin, database = db) => setPin({ db: database, fieldValue, providerId: 'provider', pin: value });
function wrappedDb(runTransaction) {
  return { collection: (name) => db.collection(name), runTransaction };
}
function abortBeforeCommit() {
  return wrappedDb((callback) => db.runTransaction(async (tx) => {
    await callback(tx);
    throw new Error('Injected interruption before commit');
  }));
}
function adminRequest(value, approve = true) {
  return { auth: { uid: 'admin', token: { firebase: { sign_in_provider: 'password' } } },
    data: { providerId: 'provider', pin: value, approve } };
}
async function seedAdmin() {
  await db.doc('admins/admin').set({ role: 'super', isActive: true });
}

test('migration commits credential and deletion together, and rerun is clean', async () => {
  await seed();
  assert.equal((await migrate()).outcome, 'needs_migration');
  const first = await state();
  assert.ok(!Object.hasOwn(first.provider, 'artisanPin'));
  assert.ok(verifySecret(oldPin, first.credential.hash));
  assert.equal((await migrate()).outcome, 'clean');
  assert.ok((await state()).credential.hash === first.credential.hash);
});

test('interruption before commit changes neither public nor private data; retry succeeds', async () => {
  await seed();
  await assert.rejects(migrate(abortBeforeCommit()), /Injected interruption/);
  const failed = await state();
  assert.ok(Object.hasOwn(failed.provider, 'artisanPin'));
  assert.ok(!failed.credential);
  await migrate();
  assert.ok(verifySecret(oldPin, (await state()).credential.hash));
});

test('lost response after commit is safely recoverable by rerunning the script', async () => {
  await seed();
  const uncertain = wrappedDb(async (callback) => {
    await db.runTransaction(callback);
    throw new Error('Injected response loss');
  });
  const report = await runMigration({ db: uncertain, admin, dryRun: false, log: () => {} });
  assert.equal(report.errors, 1);
  assert.equal(report.incomplete, true);
  assert.equal(migrationExitCode(report), 2);
  const previous = (await state()).credential.hash;
  const retry = await runMigration({ db, admin, dryRun: false, log: () => {} });
  assert.equal(retry.alreadyClean, 1);
  assert.equal(retry.incomplete, false);
  assert.ok((await state()).credential.hash === previous);
});

test('an old partial migration resumes only after verifying the existing credential', async () => {
  const credential = { hash: hashSecret(oldPin) };
  await seed({ credential });
  const result = await migrate();
  assert.equal(result.outcome, 'resume_cleanup');
  const current = await state();
  assert.ok(current.credential.hash === credential.hash);
  assert.ok(!Object.hasOwn(current.provider, 'artisanPin'));
});

test('conflicting or invalid credentials are reported without overwriting or deleting data', async () => {
  for (const credential of [{ hash: hashSecret(newPin) }, { hash: 'invalid' }]) {
    await seed({ credential });
    const result = await migrate();
    assert.equal(result.outcome, 'anomaly');
    const current = await state();
    assert.ok(current.credential.hash === credential.hash);
    assert.ok(Object.hasOwn(current.provider, 'artisanPin'));
  }
  const report = await runMigration({ db, admin, dryRun: false, log: () => {} });
  assert.equal(report.anomalies, 1);
  assert.equal(report.incomplete, true);
  assert.equal(migrationExitCode(report), 2);
});

test('dry-run checks real credentials but does not change any documents', async () => {
  await seed();
  const report = await runMigration({ db, admin, log: () => {} });
  assert.equal(report.dryRun, true);
  assert.equal(report.needsMigration, 1);
  assert.equal(report.applied, 0);
  const current = await state();
  assert.ok(Object.hasOwn(current.provider, 'artisanPin'));
  assert.ok(!current.credential);
});

test('migration racing a PIN rotation never restores the historical PIN', { timeout: 30000 }, async () => {
  await seed();
  await Promise.all([migrate(), rotate()]);
  const current = await state();
  assert.ok(verifySecret(newPin, current.credential.hash));
  assert.ok(!verifySecret(oldPin, current.credential.hash));
  assert.ok(!Object.hasOwn(current.provider, 'artisanPin'));
});

test('legacy login racing a rotation cannot overwrite the rotated credential', { timeout: 30000 }, async () => {
  await seed();
  const login = buildArtisanLogin({ db, fieldValue, checkRateLimit: async () => {} });
  await Promise.all([login({ auth: { uid: 'artisan' }, data: { phone, pin: oldPin } }), rotate()]);
  const current = await state();
  assert.ok(verifySecret(newPin, current.credential.hash));
  assert.ok(!Object.hasOwn(current.provider, 'artisanPin'));
  const result = await login({ auth: { uid: 'artisan' }, data: { phone, pin: newPin } });
  assert.equal(result.success, true);
  assert.ok(!Object.hasOwn(result.data, 'artisanPin'));
  assert.ok(!Object.hasOwn(result.data, 'hash'));
});

test('simultaneous phone reset and migration preserve the reset and existing account', { timeout: 30000 }, async () => {
  await seed();
  const reset = buildResetAccountPassword({ db, auth: {}, fieldValue, hashSecret, checkRateLimit: async () => {} });
  await Promise.all([migrate(), reset({
    auth: { uid: 'verified-phone', token: { phone_number: '+2250700000000' } },
    data: { userType: 'artisan', phone, newValue: newPin },
  })]);
  const current = await state();
  assert.ok(verifySecret(newPin, current.credential.hash));
  assert.ok(!Object.hasOwn(current.provider, 'artisanPin'));
});

test('two simultaneous resets serialize; the final credential is valid and no plaintext remains', { timeout: 30000 }, async () => {
  await seed({ legacy: false, credential: { hash: hashSecret(oldPin) } });
  const otherPin = pin();
  await Promise.all([rotate(), rotate(otherPin)]);
  const current = await state();
  assert.ok(verifySecret(newPin, current.credential.hash) || verifySecret(otherPin, current.credential.hash));
  assert.ok(!Object.hasOwn(current.provider, 'artisanPin'));
});

test('approval succeeds atomically and a replay cannot reset a subsequently changed PIN', async () => {
  await seed({ legacy: false });
  await seedAdmin();
  const approve = buildSetArtisanPin({ db, fieldValue });
  const first = await approve(adminRequest(oldPin));
  assert.equal(first.pinSet, true);
  assert.equal((await state()).provider.status, 'approved');
  assert.ok(verifySecret(oldPin, (await state()).credential.hash));
  const replay = await approve(adminRequest(oldPin));
  assert.equal(replay.alreadyApproved, true);
  assert.equal(replay.pinSet, true);
  assert.equal((await db.collection('audit_logs').get()).size, 1);
  await rotate();
  assert.equal((await approve(adminRequest(oldPin))).pinSet, false);
  assert.ok(verifySecret(newPin, (await state()).credential.hash));
});

test('failed approval leaves the account pending without a partial credential', async () => {
  await seed({ legacy: false });
  await seedAdmin();
  const approve = buildSetArtisanPin({ db: abortBeforeCommit(), fieldValue });
  await assert.rejects(approve(adminRequest(oldPin)), /Injected interruption/);
  const current = await state();
  assert.equal(current.provider.status, 'pending');
  assert.ok(!current.credential);
  assert.equal((await db.collection('audit_logs').get()).size, 0);
  const retry = buildSetArtisanPin({ db, fieldValue });
  assert.equal((await retry(adminRequest(oldPin))).success, true);
});

test('simultaneous approvals cannot publish two different PINs', { timeout: 30000 }, async () => {
  await seed({ legacy: false });
  await seedAdmin();
  const approve = buildSetArtisanPin({ db, fieldValue });
  const results = await Promise.all([approve(adminRequest(oldPin)), approve(adminRequest(newPin))]);
  assert.equal(results.filter((r) => r.pinSet).length, 1);
  assert.equal((await state()).provider.status, 'approved');
  assert.equal((await db.collection('audit_logs').get()).size, 1);
});

test('approval denies unauthorized callers and does not approve invalid PIN requests', async () => {
  await seed({ legacy: false });
  const approve = buildSetArtisanPin({ db, fieldValue });
  await assert.rejects(approve(adminRequest(oldPin)), (e) => e.code === 'permission-denied');
  await seedAdmin();
  await assert.rejects(approve(adminRequest('invalid')), (e) => e.code === 'invalid-argument');
  assert.equal((await state()).provider.status, 'pending');
  assert.ok(!(await state()).credential);
});
