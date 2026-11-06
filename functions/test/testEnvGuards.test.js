'use strict';

// Garde-fous du projet de test (test-env/) : jamais de production, jamais de SMS/paiement réel.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const g = require('../../test-env/lib/guards');

const seed = path.join(__dirname, '..', '..', 'test-env', 'seed-test-data.js');
const run = (args, env = {}) => spawnSync(process.execPath, [seed, ...args], {
  env: { PATH: process.env.PATH, ...env }, encoding: 'utf8',
});

test('assertTestProject : production et noms non explicites refusés', () => {
  for (const id of ['az-express-b0469', 'AZ-Express-B0469', 'az-express-clean', 'mon-projet', '', undefined]) {
    assert.throws(() => g.assertTestProject(id), undefined, String(id));
  }
  assert.equal(g.assertTestProject('az-express-test'), 'az-express-test');
  assert.equal(g.assertTestProject('demo-az-test'), 'demo-az-test');
  assert.equal(g.assertTestProject('az-express-preprod'), 'az-express-preprod');
});

test('assertNoProductionEnv : variable visant la production refusée', () => {
  assert.throws(() => g.assertNoProductionEnv({ GOOGLE_CLOUD_PROJECT: 'az-express-b0469' }));
  assert.throws(() => g.assertNoProductionEnv({ GCLOUD_PROJECT: 'az-express-clean' }));
  assert.doesNotThrow(() => g.assertNoProductionEnv({ GOOGLE_CLOUD_PROJECT: 'az-express-test' }));
});

test('findProductionReferences : id, numéro de projet et appId de production détectés', () => {
  assert.deepEqual(g.findProductionReferences('{"project_id":"az-express-b0469"}'), ['az-express-b0469']);
  assert.ok(g.findProductionReferences('sender 697217052961').includes('697217052961'));
  assert.ok(g.findProductionReferences('1:1:android:c645fe608310b5f6ea4e60').length > 0);
  assert.deepEqual(g.findProductionReferences('{"project_id":"az-express-test"}'), []);
});

test('functions.env : SMS et paiements réels doivent être désactivés', () => {
  const base = 'DELIVERY_SMS_ENABLED=false\nDELIVERY_SMS_PROVIDER=none\n';
  const ok = `${base}FEEXPAY_SHOP_ID=DISABLED\n`;
  assert.deepEqual(g.checkFunctionsEnv(ok), []);
  assert.ok(g.checkFunctionsEnv('DELIVERY_SMS_ENABLED=true').length > 0);
  assert.ok(g.checkFunctionsEnv('').length > 0); // absent = non prouvé désactivé
  assert.ok(g.checkFunctionsEnv(`${base}FEEXPAY_SHOP_ID=shop_reel`).length > 0);
  assert.ok(g.checkFunctionsEnv(base).length > 0); // shop id hérité de functions/.env de production
  assert.ok(g.checkFunctionsEnv(`${ok}FEEXPAY_TOKEN=tok_reel`).length > 0);
  assert.ok(g.checkFunctionsEnv(`${ok}DELIVERY_SMS_PROVIDER=twilio`).length > 0);
  assert.deepEqual(g.checkFunctionsEnv(`${ok}FEEXPAY_TOKEN=DISABLED`), []);
});

test('dart-defines : projet de test uniquement, valeurs renseignées, bucket cohérent', () => {
  const good = { FIREBASE_PROJECT_ID: 'az-express-test', FIREBASE_ANDROID_APP_ID: '1:1:android:x',
    FIREBASE_ANDROID_API_KEY: 'k', FIREBASE_MESSAGING_SENDER_ID: '1', FIREBASE_STORAGE_BUCKET: 'az-express-test.firebasestorage.app' };
  assert.deepEqual(g.checkDartDefines(good), []);
  assert.ok(g.checkDartDefines({ ...good, FIREBASE_PROJECT_ID: 'az-express-b0469' }).length > 0);
  assert.ok(g.checkDartDefines({ ...good, FIREBASE_ANDROID_APP_ID: '<à renseigner>' }).length > 0);
  assert.ok(g.checkDartDefines({ ...good, FIREBASE_STORAGE_BUCKET: 'autre.firebasestorage.app' }).length > 0);
});

test('checkPreprodBuild : garde de démarrage, projet, numéro, package, app et clé cohérents ou refus', () => {
  const key = 'AIzaFAKE_KEY_FOR_TEST_ONLY_0000000000000';
  const defines = { AZ_REQUIRED_FIREBASE_PROJECT: 'az-express-preprod', FIREBASE_PROJECT_ID: 'az-express-preprod',
    FIREBASE_ANDROID_APP_ID: '1:306761725053:android:abc', FIREBASE_ANDROID_API_KEY: key,
    FIREBASE_MESSAGING_SENDER_ID: '306761725053', FIREBASE_STORAGE_BUCKET: 'az-express-preprod.firebasestorage.app', DELIVERY_PROOFS_UI: true, DISABLE_FCM: true };
  const gs = { project_info: { project_id: 'az-express-preprod', project_number: '306761725053', storage_bucket: 'az-express-preprod.firebasestorage.app' },
    client: [{ client_info: { mobilesdk_app_id: '1:306761725053:android:abc', android_client_info: { package_name: 'com.azexpress.app.test' } },
      api_key: [{ current_key: key }] }] };
  assert.deepEqual(g.checkPreprodBuild(defines, gs), []);
  const bad = (d, s = gs) => g.checkPreprodBuild({ ...defines, ...d }, s).length > 0;
  assert.ok(bad({ AZ_REQUIRED_FIREBASE_PROJECT: undefined }), 'garde absente');
  assert.ok(bad({ AZ_REQUIRED_FIREBASE_PROJECT: 'az-express-b0469' }), 'garde = production');
  assert.ok(bad({ FIREBASE_PROJECT_ID: 'az-express-test' }), 'autre projet');
  assert.ok(bad({ FIREBASE_MESSAGING_SENDER_ID: '697217052961' }), 'numéro de production');
  assert.ok(bad({ DELIVERY_PROOFS_UI: false }), 'preuves coupées');
  assert.ok(bad({ DISABLE_FCM: undefined }), 'FCM non désactivé (absent)');
  assert.ok(bad({ DISABLE_FCM: false }), 'FCM non désactivé (false)');
  assert.ok(bad({ DISABLE_FCM: 'false' }), 'FCM non désactivé (texte)');
  assert.deepEqual(g.checkPreprodBuild({ ...defines, DISABLE_FCM: 'true' }, gs), []);
  assert.ok(bad({ FIREBASE_ANDROID_APP_ID: '1:306761725053:android:autre' }), 'app incohérente');
  assert.ok(bad({ FIREBASE_ANDROID_API_KEY: 'AIzaAUTRE' }), 'clé incohérente');
  assert.ok(bad({}, null), 'google-services absent');
  assert.ok(bad({}, { ...gs, project_info: { ...gs.project_info, project_id: 'az-express-b0469' } }), 'google-services de production');
  assert.ok(bad({}, { ...gs, project_info: { ...gs.project_info, project_number: '697217052961' } }), 'numéro de production');
  const pkg = (name) => ({ ...gs, client: [{ ...gs.client[0], client_info: { ...gs.client[0].client_info, android_client_info: { package_name: name } } }] });
  assert.ok(bad({}, pkg('com.azexpress.app')), 'package de production');
  assert.ok(bad({}, { ...gs, client: [...gs.client, ...gs.client] }), 'plusieurs apps');
});

test('seed-test-data.js : refuse la production, un nom ambigu, l’absence de confirmation et un env de production', () => {
  const env = { AZ_TEST_PASSWORD: 'motdepasse-test-12' };
  assert.equal(run(['--project', 'az-express-b0469', '--confirm-project', 'az-express-b0469'], env).status, 1);
  assert.equal(run(['--project', 'mon-projet', '--confirm-project', 'mon-projet'], env).status, 1);
  const noConfirm = run(['--project', 'az-express-test'], env);
  assert.equal(noConfirm.status, 1);
  assert.match(noConfirm.stderr, /confirm-project/);
  const prodEnv = run(['--project', 'az-express-test', '--confirm-project', 'az-express-test'],
    { ...env, GOOGLE_CLOUD_PROJECT: 'az-express-b0469' });
  assert.equal(prodEnv.status, 1);
  assert.match(prodEnv.stderr, /production/i);
  const weak = run(['--project', 'az-express-test', '--confirm-project', 'az-express-test'], { AZ_TEST_PASSWORD: 'court' });
  assert.equal(weak.status, 1);
});
