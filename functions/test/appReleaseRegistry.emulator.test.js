'use strict';

// Outil de saisie du registre + garde de setAppVersionsConfigCF, contre l'ÉMULATEUR Firestore uniquement (projet demo-*).
//   npx firebase emulators:exec --only firestore --project demo-m23 "node --test functions/test/appReleaseRegistry.emulator.test.js"
const test = require('node:test');
const assert = require('node:assert/strict');

const emulated = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const options = { skip: emulated ? false : 'émulateur Firestore requis' };

test('saisie réelle (émulateur) puis déblocage de minBuild par la fonction', options, async () => {
  const admin = require('firebase-admin');
  const { HttpsError } = require('firebase-functions/v2/https');
  const { main } = require('../scripts/appReleaseRegistry');
  const { requireSuperAdmin } = require('../adminGuards');
  const { buildSetAppVersionsConfig } = require('../appVersionsAdmin');
  const now = new Date('2026-11-12T12:00:00Z');
  const argv = (platform, build) => ['--project', 'demo-m23', '--platform', platform, '--build', String(build),
    '--source', platform === 'android' ? 'google-play-console' : 'app-store-connect', '--detail', 'Console de test émulateur', '--verified-at', '2026-11-12T09:30:00Z', '--evidence', 'preuve-test', '--operator', 'op'];
  const env = { FIRESTORE_EMULATOR_HOST: process.env.FIRESTORE_EMULATOR_HOST };

  // Simulation : n'écrit rien.
  assert.equal(await main(argv('android', 11), env, () => {}, now), 'dry-run');
  admin.initializeApp({ projectId: 'demo-m23' });
  const db = admin.firestore();
  assert.equal((await db.doc('config/app_release_registry').get()).exists, false);

  await main([...argv('android', 11), '--apply', '--confirm', 'demo-m23:android:11'], env, () => {}, now);
  await main([...argv('ios', 4), '--apply', '--confirm', 'demo-m23:ios:4'], env, () => {}, now);
  const reg = (await db.doc('config/app_release_registry').get()).data();
  assert.equal(reg.android.latestBuild, 11); assert.equal(reg.ios.latestBuild, 4);
  assert.equal(reg.android.verifiedAt.toDate().toISOString(), '2026-11-12T09:30:00.000Z');
  assert.equal((await db.collection('audit_logs').where('action', '==', 'app_release_registry_update').get()).size, 2);
  await assert.rejects(main([...argv('android', 10), '--apply', '--confirm', 'demo-m23:android:10'], env, () => {}, now), (e) => e.code === 'BUILD_DECREASE');

  await db.doc('admins/root').set({ role: 'super', isActive: true });
  const fn = buildSetAppVersionsConfig({ db, admin, onCall: (h) => ({ run: h }), HttpsError,
    checkRateLimit: async () => {}, logAudit: async () => {}, requireSuperAdmin });
  const as = (data) => ({ auth: { uid: 'root', token: { firebase: { sign_in_provider: 'password' } } }, data });
  assert.equal((await fn.run(as({ role: 'driver', expectedVersion: 0, values: { minBuildAndroid: 11, minBuildIos: 4 } }))).success, true);
  assert.equal((await fn.run(as({ role: 'client', expectedVersion: 1, values: { minBuildIos: 5 } }))).code, 'BUILD_ABOVE_PUBLISHED');
});
