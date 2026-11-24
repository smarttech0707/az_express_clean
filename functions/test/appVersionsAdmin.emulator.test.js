'use strict';

// Intégration contre l'émulateur Firestore (jamais la production). Ignoré hors émulateur. Exécution :
//   npx firebase emulators:exec --only firestore --project demo-m22 \
//     "node --test functions/test/appVersionsAdmin.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

let admin; let db; let fn; let audits;

test.before(async () => {
  if (!emulated) return;
  admin = require('firebase-admin');
  admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'demo-m22' });
  db = admin.firestore();
  audits = [];
  const { HttpsError } = require('firebase-functions/v2/https');
  const { requireSuperAdmin } = require('../adminGuards');
  const { buildSetAppVersionsConfig } = require('../appVersionsAdmin');
  fn = buildSetAppVersionsConfig({
    db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async (d) => { audits.push(d); }, requireSuperAdmin,
  });
  await db.doc('admins/root').set({ role: 'super', isActive: true });
  await db.doc('admins/sub').set({ role: 'sub', isActive: true, permissions: ['commandes'] });
});

const as = (uid, data) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, data });

test('écriture réelle : refus sans registre, puis succès après vérification manuelle du registre', options, async () => {
  const refused = await fn.run(as('root', { role: 'driver', expectedVersion: 0, values: { minBuild: 12 } }));
  assert.equal(refused.code, 'PUBLISHED_BUILD_UNVERIFIED');
  assert.equal((await db.doc('config/app_versions').get()).exists, false);

  await db.doc('config/app_release_registry').set({
    android: { latestBuild: 12, source: 'test', verifiedAt: admin.firestore.Timestamp.now() },
    ios: { latestBuild: 3, source: 'test', verifiedAt: admin.firestore.Timestamp.now() },
  });
  const ok = await fn.run(as('root', { role: 'driver', expectedVersion: 0, values: { minBuildAndroid: 12, minBuildIos: 3, enforce: false } }));
  assert.equal(ok.success, true);
  const doc = (await db.doc('config/app_versions').get()).data();
  assert.deepEqual(doc.driver, { minBuildAndroid: 12, minBuildIos: 3, enforce: false });
  assert.equal(doc.version, 1); assert.equal(doc.updatedBy, 'root');
  assert.ok(doc.updatedAt);
  assert.equal(audits.at(-1).status, 'success');

  assert.equal((await fn.run(as('root', { role: 'driver', expectedVersion: 0, values: { minBuild: 1 } }))).code, 'VERSION_CONFLICT');
  assert.equal((await fn.run(as('root', { role: 'driver', expectedVersion: 1, values: { enforce: true } }))).code, 'ENFORCE_NOT_ALLOWED');
  assert.equal((await fn.run(as('root', { role: 'client', expectedVersion: 1, values: { minBuild: 13 } }))).code, 'BUILD_ABOVE_PUBLISHED');
  assert.equal((await fn.run(as('root', { role: 'driver', expectedVersion: 1, values: null }))).success, true);
  assert.equal('driver' in (await db.doc('config/app_versions').get()).data(), false);
});

test('écriture réelle : sous-admin et inconnu refusés, document inchangé', options, async () => {
  const before = (await db.doc('config/app_versions').get()).data();
  for (const uid of ['sub', 'ghost']) {
    await assert.rejects(fn.run(as(uid, { role: 'driver', expectedVersion: 2, values: { message: 'x' } })),
      (e) => e.code === 'permission-denied');
  }
  assert.deepEqual((await db.doc('config/app_versions').get()).data(), before);
});
